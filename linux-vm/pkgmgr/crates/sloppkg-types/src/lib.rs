use std::cmp::Ordering;
use std::collections::BTreeMap;
use std::fmt;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum VersionParseError {
    #[error("invalid version expression: {0}")]
    Invalid(String),
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Evr {
    pub epoch: u64,
    pub version: String,
    pub release: String,
}

impl Evr {
    pub fn new(epoch: u64, version: impl Into<String>, release: impl Into<String>) -> Self {
        Self {
            epoch,
            version: version.into(),
            release: release.into(),
        }
    }

    pub fn parse(input: &str) -> Result<Self, VersionParseError> {
        let trimmed = input.trim();
        if trimmed.is_empty() {
            return Err(VersionParseError::Invalid(input.to_owned()));
        }

        let (epoch, rest) = match trimmed.split_once(':') {
            Some((epoch, rest)) => (
                epoch
                    .parse::<u64>()
                    .map_err(|_| VersionParseError::Invalid(input.to_owned()))?,
                rest,
            ),
            None => (0, trimmed),
        };

        let (version, release) = match rest.rsplit_once('-') {
            Some((version, release)) if !version.is_empty() && !release.is_empty() => {
                (version.to_owned(), release.to_owned())
            }
            _ => (rest.to_owned(), String::from("0")),
        };

        if version.is_empty() {
            return Err(VersionParseError::Invalid(input.to_owned()));
        }

        Ok(Self::new(epoch, version, release))
    }
}

impl fmt::Display for Evr {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.epoch == 0 {
            write!(f, "{}-{}", self.version, self.release)
        } else {
            write!(f, "{}:{}-{}", self.epoch, self.version, self.release)
        }
    }
}

impl Ord for Evr {
    fn cmp(&self, other: &Self) -> Ordering {
        self.epoch
            .cmp(&other.epoch)
            .then_with(|| rpm_cmp(&self.version, &other.version))
            .then_with(|| rpm_cmp(&self.release, &other.release))
    }
}

impl PartialOrd for Evr {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

fn rpm_cmp(left: &str, right: &str) -> Ordering {
    let mut left = left;
    let mut right = right;

    loop {
        left = left.trim_start_matches(|c: char| !c.is_ascii_alphanumeric());
        right = right.trim_start_matches(|c: char| !c.is_ascii_alphanumeric());

        if left.is_empty() || right.is_empty() {
            return left.is_empty().cmp(&right.is_empty()).reverse();
        }

        let left_is_num = left.as_bytes()[0].is_ascii_digit();
        let right_is_num = right.as_bytes()[0].is_ascii_digit();

        if left_is_num != right_is_num {
            return if left_is_num {
                Ordering::Greater
            } else {
                Ordering::Less
            };
        }

        let left_len = left
            .chars()
            .take_while(|c| c.is_ascii_digit() == left_is_num && c.is_ascii_alphanumeric())
            .count();
        let right_len = right
            .chars()
            .take_while(|c| c.is_ascii_digit() == right_is_num && c.is_ascii_alphanumeric())
            .count();

        let left_part = &left[..left_len];
        let right_part = &right[..right_len];

        let ordering = if left_is_num {
            let left_trimmed = left_part.trim_start_matches('0');
            let right_trimmed = right_part.trim_start_matches('0');
            left_trimmed
                .len()
                .cmp(&right_trimmed.len())
                .then_with(|| left_trimmed.cmp(right_trimmed))
        } else {
            left_part.cmp(right_part)
        };

        if ordering != Ordering::Equal {
            return ordering;
        }

        left = &left[left_len..];
        right = &right[right_len..];
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Constraint {
    Any,
    All(Vec<Comparator>),
}

impl Constraint {
    pub fn parse(input: &str) -> Result<Self, VersionParseError> {
        let trimmed = input.trim();
        if trimmed.is_empty() || trimmed == "*" {
            return Ok(Self::Any);
        }

        if let Some(rest) = trimmed.strip_prefix('^') {
            let base = Evr::parse(rest)?;
            let upper = next_major(&base)?;
            return Ok(Self::All(vec![
                Comparator::new(CmpOp::GreaterEq, base),
                Comparator::new(CmpOp::Less, upper),
            ]));
        }

        if let Some(rest) = trimmed.strip_prefix('~') {
            let base = Evr::parse(rest)?;
            let upper = next_minor(&base)?;
            return Ok(Self::All(vec![
                Comparator::new(CmpOp::GreaterEq, base),
                Comparator::new(CmpOp::Less, upper),
            ]));
        }

        let comparators = trimmed
            .split(',')
            .map(str::trim)
            .filter(|part| !part.is_empty())
            .map(Comparator::parse)
            .collect::<Result<Vec<_>, _>>()?;

        if comparators.is_empty() {
            Ok(Self::Any)
        } else {
            Ok(Self::All(comparators))
        }
    }

    pub fn matches(&self, candidate: &Evr) -> bool {
        match self {
            Constraint::Any => true,
            Constraint::All(comparators) => comparators.iter().all(|cmp| cmp.matches(candidate)),
        }
    }
}

impl fmt::Display for Constraint {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Constraint::Any => write!(f, "*"),
            Constraint::All(parts) => {
                let joined = parts
                    .iter()
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
                    .join(", ");
                write!(f, "{joined}")
            }
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Comparator {
    pub op: CmpOp,
    pub version: Evr,
}

impl Comparator {
    pub fn new(op: CmpOp, version: Evr) -> Self {
        Self { op, version }
    }

    pub fn parse(input: &str) -> Result<Self, VersionParseError> {
        for op in [">=", "<=", "!=", "=", ">", "<"] {
            if let Some(rest) = input.strip_prefix(op) {
                return Ok(Self::new(CmpOp::parse(op)?, Evr::parse(rest.trim())?));
            }
        }

        Ok(Self::new(CmpOp::Equal, Evr::parse(input.trim())?))
    }

    pub fn matches(&self, candidate: &Evr) -> bool {
        match self.op {
            CmpOp::Equal => candidate == &self.version,
            CmpOp::NotEqual => candidate != &self.version,
            CmpOp::Less => candidate < &self.version,
            CmpOp::LessEq => candidate <= &self.version,
            CmpOp::Greater => candidate > &self.version,
            CmpOp::GreaterEq => candidate >= &self.version,
        }
    }
}

impl fmt::Display for Comparator {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} {}", self.op, self.version)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CmpOp {
    Equal,
    NotEqual,
    Less,
    LessEq,
    Greater,
    GreaterEq,
}

impl CmpOp {
    fn parse(input: &str) -> Result<Self, VersionParseError> {
        match input {
            "=" => Ok(Self::Equal),
            "!=" => Ok(Self::NotEqual),
            "<" => Ok(Self::Less),
            "<=" => Ok(Self::LessEq),
            ">" => Ok(Self::Greater),
            ">=" => Ok(Self::GreaterEq),
            _ => Err(VersionParseError::Invalid(input.to_owned())),
        }
    }
}

impl fmt::Display for CmpOp {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let text = match self {
            CmpOp::Equal => "=",
            CmpOp::NotEqual => "!=",
            CmpOp::Less => "<",
            CmpOp::LessEq => "<=",
            CmpOp::Greater => ">",
            CmpOp::GreaterEq => ">=",
        };
        write!(f, "{text}")
    }
}

fn next_major(base: &Evr) -> Result<Evr, VersionParseError> {
    let mut parts = split_numeric_prefix(&base.version)?;
    if parts.is_empty() {
        return Err(VersionParseError::Invalid(base.version.clone()));
    }
    parts[0] += 1;
    for part in parts.iter_mut().skip(1) {
        *part = 0;
    }
    Ok(Evr::new(base.epoch, join_parts(&parts), 0.to_string()))
}

fn next_minor(base: &Evr) -> Result<Evr, VersionParseError> {
    let mut parts = split_numeric_prefix(&base.version)?;
    if parts.is_empty() {
        return Err(VersionParseError::Invalid(base.version.clone()));
    }
    if parts.len() == 1 {
        parts.push(1);
    } else {
        parts[1] += 1;
        for part in parts.iter_mut().skip(2) {
            *part = 0;
        }
    }
    Ok(Evr::new(base.epoch, join_parts(&parts), 0.to_string()))
}

fn split_numeric_prefix(version: &str) -> Result<Vec<u64>, VersionParseError> {
    version
        .split('.')
        .map(|part| {
            part.chars()
                .take_while(|c| c.is_ascii_digit())
                .collect::<String>()
                .parse::<u64>()
                .map_err(|_| VersionParseError::Invalid(version.to_owned()))
        })
        .collect()
}

fn join_parts(parts: &[u64]) -> String {
    parts
        .iter()
        .map(u64::to_string)
        .collect::<Vec<_>>()
        .join(".")
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RepoKind {
    Recipe,
    Binary,
    Unified,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum RepoTrustMode {
    Local,
    DigestPinned,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum RepoSyncStrategy {
    File,
    StaticHttp,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct RepoConfigEntry {
    pub name: String,
    pub kind: RepoKind,
    pub url: String,
    #[serde(default)]
    pub channel: Option<String>,
    #[serde(default = "default_priority")]
    pub priority: i32,
    #[serde(default = "default_enabled")]
    pub enabled: bool,
    #[serde(default = "default_trust_mode")]
    pub trust_policy: RepoTrustMode,
    #[serde(default = "default_sync_strategy")]
    pub sync_strategy: RepoSyncStrategy,
}

const fn default_priority() -> i32 {
    50
}

const fn default_enabled() -> bool {
    true
}

const fn default_trust_mode() -> RepoTrustMode {
    RepoTrustMode::Local
}

const fn default_sync_strategy() -> RepoSyncStrategy {
    RepoSyncStrategy::File
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct RepoConfigFile {
    #[serde(default)]
    pub repo: Vec<RepoConfigEntry>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RepoCapability {
    Recipes,
    Binaries,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct UnifiedRepoMetadata {
    pub format_version: u32,
    pub name: String,
    pub kind: RepoKind,
    pub generated_at: String,
    pub default_channel: String,
    #[serde(default)]
    pub capabilities: Vec<RepoCapability>,
    pub recipes: UnifiedRecipeCollection,
    #[serde(default)]
    pub binaries: BTreeMap<String, UnifiedBinaryChannel>,
    pub trust: UnifiedRepoTrust,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct UnifiedRecipeCollection {
    #[serde(default)]
    pub channels: BTreeMap<String, RecipeChannelMetadata>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct UnifiedBinaryChannel {
    pub current_revision: String,
    pub index_path: String,
    pub index_sha256: String,
    #[serde(default = "default_zst_compression")]
    pub compression: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct UnifiedRepoTrust {
    pub mode: RepoTrustMode,
    #[serde(default = "default_signature_mode")]
    pub signatures: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct RecipeChannelMetadata {
    pub current_revision: String,
    pub index_path: String,
    pub index_sha256: String,
    #[serde(default = "default_zst_compression")]
    pub compression: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct RecipeSnapshotIndex {
    pub format_version: u32,
    pub repo_name: String,
    pub channel: String,
    pub revision: String,
    pub generated_at: String,
    #[serde(default)]
    pub recipes: Vec<RecipeIndexPackage>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct RecipeIndexPackage {
    pub name: String,
    #[serde(default)]
    pub versions: Vec<RecipeIndexVersion>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct RecipeIndexVersion {
    #[serde(default)]
    pub epoch: u64,
    pub version: String,
    pub release: String,
    pub manifest_path: String,
    pub manifest_sha256: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct RecipeBundleManifest {
    pub format_version: u32,
    pub package_name: String,
    #[serde(default)]
    pub epoch: u64,
    pub version: String,
    pub release: String,
    #[serde(default)]
    pub files: Vec<RecipeBundleFile>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct RecipeBundleFile {
    pub path: String,
    pub sha256: String,
}

fn default_zst_compression() -> String {
    String::from("zst")
}

fn default_signature_mode() -> String {
    String::from("none")
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DependencyKind {
    Runtime,
    Build,
    Optional,
    Test,
}

impl DependencyKind {
    pub fn is_runtime(self) -> bool {
        matches!(self, DependencyKind::Runtime)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Dependency {
    pub name: String,
    pub constraint: Constraint,
    pub kind: DependencyKind,
    pub reason: Option<String>,
    pub feature: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DependencyGroup {
    pub kind: DependencyKind,
    pub one_of: Vec<Dependency>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Capability {
    pub name: String,
    pub constraint: Constraint,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PackageMeta {
    pub name: String,
    pub evr: Evr,
    pub summary: String,
    pub description: String,
    pub license: String,
    pub homepage: Option<String>,
    pub architectures: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SourceSpec {
    pub kind: String,
    pub url: String,
    pub sha256: String,
    pub filename: Option<String>,
    pub strip_components: usize,
    pub destination: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BuildSpec {
    pub system: String,
    pub out_of_tree: bool,
    pub directory: Option<String>,
    pub env: Vec<(String, String)>,
    pub configure: Vec<String>,
    pub build: Vec<String>,
    pub install: Vec<String>,
    pub jobs: usize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InstallSpec {
    pub prefix: String,
    pub sysconfdir: String,
    pub localstatedir: String,
    pub owned_prefixes: Vec<String>,
    pub strip_binaries: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BootstrapSpec {
    pub sysroot: String,
    pub stages: Vec<BootstrapStage>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BootstrapStage {
    pub name: String,
    pub packages: Vec<String>,
    pub depends_on: Vec<String>,
    pub env: Vec<(String, String)>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PackageRecord {
    pub repo_name: String,
    pub repo_priority: i32,
    pub recipe_path: PathBuf,
    pub source_path: PathBuf,
    pub package: PackageMeta,
    pub sources: Vec<SourceSpec>,
    pub build: BuildSpec,
    pub install: InstallSpec,
    pub dependencies: Vec<Dependency>,
    pub dependency_groups: Vec<DependencyGroup>,
    pub provides: Vec<Capability>,
    pub conflicts: Vec<Capability>,
    pub replaces: Vec<Capability>,
    pub bootstrap: Option<BootstrapSpec>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct BinaryDependency {
    pub name: String,
    pub constraint: String,
    pub kind: DependencyKind,
    pub reason: Option<String>,
    pub feature: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct BinaryDependencyGroup {
    pub kind: DependencyKind,
    pub one_of: Vec<BinaryDependency>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct BinaryCapability {
    pub name: String,
    pub constraint: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct BinaryPackageInfo {
    pub package_name: String,
    pub epoch: u64,
    pub version: String,
    pub release: String,
    pub arch: String,
    pub repo_name: String,
    pub source_path: String,
    pub summary: String,
    pub description: String,
    pub license: String,
    pub homepage: Option<String>,
    #[serde(default = "default_owned_prefixes")]
    pub owned_prefixes: Vec<String>,
    pub dependencies: Vec<BinaryDependency>,
    pub dependency_groups: Vec<BinaryDependencyGroup>,
    pub provides: Vec<BinaryCapability>,
    pub conflicts: Vec<BinaryCapability>,
    pub replaces: Vec<BinaryCapability>,
}

fn default_owned_prefixes() -> Vec<String> {
    vec![String::from("/usr/local")]
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct PackageManifest {
    pub package_name: String,
    pub version: String,
    pub entries: Vec<ManifestEntry>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ManifestEntry {
    pub path: String,
    pub file_type: String,
    pub mode: u32,
    pub size: u64,
    pub sha256: Option<String>,
    pub link_target: Option<String>,
    pub config_file: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RequestedPackage {
    pub name: String,
    pub constraint: Constraint,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PlannedPackage {
    pub package: PackageRecord,
    pub reason: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TransactionPlan {
    pub requested: Vec<RequestedPackage>,
    pub packages: Vec<PlannedPackage>,
}

#[cfg(test)]
mod tests {
    use super::{Constraint, Evr};

    #[test]
    fn evr_compares_epoch_version_release() {
        assert!(Evr::parse("1:1.0.0-1").unwrap() > Evr::parse("1.9.9-9").unwrap());
        assert!(Evr::parse("1.3.1-2").unwrap() > Evr::parse("1.3.1-1").unwrap());
        assert!(Evr::parse("1.10.0-1").unwrap() > Evr::parse("1.9.9-1").unwrap());
    }

    #[test]
    fn constraint_supports_ranges() {
        let req = Constraint::parse(">= 1.3.0-1, < 2.0.0-0").unwrap();
        assert!(req.matches(&Evr::parse("1.3.1-1").unwrap()));
        assert!(!req.matches(&Evr::parse("2.0.0-1").unwrap()));
    }
}
