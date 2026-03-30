use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque};
use std::fmt::Write as _;
use std::fs;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use sloppkg_build::{
    fetch_package_sources, stage_package, BuildError, BuildReport, SourceFetchReport,
};
use sloppkg_db::{
    check as check_db, create_transaction, find_cache_packages,
    find_installed_file_conflicts_excluding, initialize as init_db, list_installed_dependencies,
    list_installed_files_for_package, list_installed_packages, list_transaction_statuses,
    list_world_entries, record_cache_package, record_distfile, record_installed_package,
    remove_installed_package_records, remove_world_entry, update_transaction_status,
    upsert_world_entry, CachePackageRecord, DbError, DistfileRecord, InstalledPackageRecord,
    TransactionActionRecord, WorldEntry,
};
use sloppkg_repo::{
    cached_unified_snapshot_root, export_unified_recipe_repo, extract_binary_package,
    find_cached_binary_package, generate_binary_repo_index, load_recipe_repo, sync_unified_repo,
    BinaryRepoIndexReport, CachedBinaryPackage, RepoError, RepoSnapshot, UnifiedRepoExportReport,
    UnifiedRepoSyncReport,
};
use sloppkg_solver::{resolve as solve, SolveError, SolveOptions};
use sloppkg_types::{
    BootstrapSpec, BootstrapStage, Constraint, PackageManifest, PackageRecord, RepoConfigEntry,
    RepoConfigFile, RepoKind, RepoSyncStrategy, RepoTrustMode, RequestedPackage, TransactionPlan,
};
use thiserror::Error;

const ROOT_RUNTIME_MAINTENANCE_SCRIPTS: &[&str] = &[
    "etc/init.d/S14persistent-dropbear",
    "etc/init.d/S15local-lib-links",
    "etc/init.d/S16persistent-sloppkg",
    "etc/init.d/S17persistent-getty",
    "etc/init.d/S19persistent-sh",
    "etc/init.d/S20managed-userland-links",
];

#[derive(Clone, Debug)]
pub struct AppPaths {
    pub state_root: PathBuf,
    pub distfiles_dir: PathBuf,
    pub build_dir: PathBuf,
    pub packages_dir: PathBuf,
    pub published_repos_dir: PathBuf,
    pub repo_state_dir: PathBuf,
    pub repo_snapshots_dir: PathBuf,
    pub db_dir: PathBuf,
    pub logs_dir: PathBuf,
    pub transactions_dir: PathBuf,
    pub bootstrap_stamps_dir: PathBuf,
    pub repo_config_path: PathBuf,
    pub database_path: PathBuf,
}

impl AppPaths {
    pub fn from_state_root(state_root: PathBuf) -> Self {
        let db_dir = state_root.join("db");
        let repo_state_dir = state_root.join("repos");
        Self {
            distfiles_dir: state_root.join("distfiles"),
            build_dir: state_root.join("build"),
            packages_dir: state_root.join("packages"),
            published_repos_dir: state_root.join("published"),
            repo_snapshots_dir: repo_state_dir.join("snapshots"),
            logs_dir: state_root.join("logs"),
            transactions_dir: db_dir.join("transactions"),
            bootstrap_stamps_dir: db_dir.join("bootstrap-stamps"),
            repo_config_path: db_dir.join("repos.toml"),
            database_path: db_dir.join("state.sqlite"),
            repo_state_dir,
            db_dir,
            state_root,
        }
    }

    pub fn create_layout(&self) -> Result<(), AppError> {
        for path in [
            &self.state_root,
            &self.distfiles_dir,
            &self.build_dir,
            &self.packages_dir,
            &self.published_repos_dir,
            &self.repo_state_dir,
            &self.repo_snapshots_dir,
            &self.db_dir,
            &self.logs_dir,
            &self.transactions_dir,
            &self.bootstrap_stamps_dir,
        ] {
            fs::create_dir_all(path).map_err(|source| AppError::Io {
                path: path.clone(),
                source,
            })?;
        }
        Ok(())
    }
}

#[derive(Debug, Error)]
pub enum AppError {
    #[error("I/O failure at {path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error(transparent)]
    Db(#[from] DbError),
    #[error(transparent)]
    Repo(#[from] RepoError),
    #[error(transparent)]
    Solve(#[from] SolveError),
    #[error(transparent)]
    Build(#[from] BuildError),
    #[error(transparent)]
    Version(#[from] sloppkg_types::VersionParseError),
    #[error("failed to parse repo config at {path}: {source}")]
    RepoConfigParse {
        path: PathBuf,
        #[source]
        source: toml::de::Error,
    },
    #[error("failed to parse publish state at {path}: {source}")]
    PublishStateParse {
        path: PathBuf,
        #[source]
        source: toml::de::Error,
    },
    #[error("failed to serialize repo config: {0}")]
    RepoConfigSerialize(#[from] toml::ser::Error),
    #[error("failed to serialize JSON: {0}")]
    JsonSerialize(#[from] serde_json::Error),
    #[error("resolved plan does not contain requested package {0}")]
    MissingRequestedPackage(String),
    #[error("package contains unmanaged path {0}")]
    UnmanagedPath(String),
    #[error("installed file conflict at {path} owned by {owner}")]
    InstalledFileConflict { path: String, owner: String },
    #[error("extracted package root is missing: {0}")]
    MissingExtractedRoot(PathBuf),
    #[error(
        "planned transaction would install {incoming} over path {path} already planned for {owner}"
    )]
    PlannedFileConflict {
        path: String,
        owner: String,
        incoming: String,
    },
    #[error("package {package} is required by installed packages: {dependents}")]
    ReverseDependencyBlocked { package: String, dependents: String },
    #[error("package {0} is not installed")]
    PackageNotInstalled(String),
    #[error("no world packages are recorded")]
    NoWorldPackages,
    #[error("bootstrap installs currently require target_root=/, got {0}")]
    UnsupportedBootstrapTargetRoot(PathBuf),
    #[error("bootstrap package {package} has invalid metadata: {reason}")]
    InvalidBootstrapMetadata { package: String, reason: String },
    #[error("bootstrap package {package} references unknown stage package {stage_package}")]
    UnknownBootstrapPackage {
        package: String,
        stage_package: String,
    },
    #[error("bootstrap package {package} references unknown stage dependency {stage_dependency}")]
    UnknownBootstrapStageDependency {
        package: String,
        stage_dependency: String,
    },
    #[error("bootstrap package {package} contains duplicate stage name {stage}")]
    DuplicateBootstrapStage { package: String, stage: String },
    #[error("bootstrap package {package} contains duplicate stage package {stage_package}")]
    DuplicateBootstrapStagePackage {
        package: String,
        stage_package: String,
    },
    #[error("bootstrap package {package} has cyclic stage dependencies")]
    BootstrapCycle { package: String },
    #[error("repository {0} is not configured")]
    UnknownRepository(String),
    #[error("repository {repo} has no cached snapshot yet; run sloppkg update")]
    UnifiedRepoNotUpdated { repo: String },
    #[error("published repo {0} has no recorded publish state")]
    MissingPublishState(String),
    #[error("published revision {revision} for repo {repo} channel {channel} does not exist")]
    MissingPublishedRevision {
        repo: String,
        channel: String,
        revision: String,
    },
    #[error("published repo {repo} has no live revision for channel {channel}")]
    MissingPublishedLiveRevision { repo: String, channel: String },
    #[error("this operation requires --recipe-root or a workspace checkout")]
    MissingRecipeRoot,
    #[error("recipe path has no parent directory: {0}")]
    InvalidRecipePath(PathBuf),
    #[error("maintenance command failed: {command} exited with {status}")]
    MaintenanceCommandFailed { command: String, status: String },
    #[error(
        "transaction {transaction_id} applied package changes but post-success maintenance failed; see {transaction_path}: {reason}"
    )]
    PostTransactionMaintenanceFailed {
        transaction_id: i64,
        transaction_path: PathBuf,
        reason: String,
    },
}

#[derive(Clone, Debug, Serialize)]
pub struct RepoSummary {
    pub name: String,
    pub kind: String,
    pub url: String,
    pub channel: Option<String>,
    pub priority: i32,
    pub enabled: bool,
    pub trust_policy: String,
    pub sync_strategy: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct DoctorReport {
    pub state_root: PathBuf,
    pub database_path: PathBuf,
    pub repo_count: usize,
    pub packages_loaded: usize,
    pub status: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct UpdateRepoReport {
    pub name: String,
    pub kind: String,
    pub action: String,
    pub channel: Option<String>,
    pub revision: Option<String>,
    pub snapshot_root: Option<PathBuf>,
    pub package_count: usize,
    pub file_count: usize,
}

#[derive(Clone, Debug, Serialize)]
pub struct UpdateReport {
    pub repos: Vec<UpdateRepoReport>,
}

#[derive(Clone, Debug, Serialize)]
pub struct FetchReport {
    pub packages: Vec<SourceFetchReport>,
    pub downloaded: usize,
    pub cached: usize,
    pub local: usize,
    pub bytes_downloaded: u64,
}

#[derive(Clone, Debug, Serialize)]
pub struct RepoExportReport {
    pub repo_name: String,
    pub channel: String,
    pub revision: String,
    pub output_root: PathBuf,
    pub package_count: usize,
    pub version_count: usize,
    pub file_count: usize,
}

#[derive(Clone, Debug, Serialize)]
pub struct RepoPublishReport {
    pub repo_name: String,
    pub source_root: PathBuf,
    pub channel: String,
    pub revision: String,
    pub published_root: PathBuf,
    pub live_root: PathBuf,
    pub package_count: usize,
    pub version_count: usize,
    pub file_count: usize,
    pub keep_revisions: usize,
}

#[derive(Clone, Debug, Serialize)]
pub struct RepoPromoteReport {
    pub source_repo_name: String,
    pub source_channel: String,
    pub source_revision: String,
    pub source_published_root: PathBuf,
    pub target_repo_name: String,
    pub target_channel: String,
    pub target_revision: String,
    pub target_published_root: PathBuf,
    pub target_live_root: PathBuf,
    pub keep_revisions: usize,
}

#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum CleanupTarget {
    Builds,
    Repos,
    Published,
    All,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct PublishState {
    repo_name: String,
    source_root: String,
    channel: String,
    keep_revisions: usize,
    #[serde(default = "publish_state_remember_default")]
    remember: bool,
}

#[derive(Clone, Copy, Debug)]
pub struct RepoPublishOptions {
    pub remember_publish_state: bool,
}

impl Default for RepoPublishOptions {
    fn default() -> Self {
        Self {
            remember_publish_state: true,
        }
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub struct TransactionOptions {
    pub skip_publish_maintenance: bool,
}

#[derive(Clone, Debug, Serialize)]
pub struct CleanupEntryReport {
    pub path: PathBuf,
    pub bytes: u64,
    pub reason: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct CleanupScopeReport {
    pub scope: String,
    pub removed: Vec<CleanupEntryReport>,
    pub kept: Vec<CleanupEntryReport>,
    pub bytes_reclaimed: u64,
}

#[derive(Clone, Debug, Serialize)]
pub struct CleanupReport {
    pub target: String,
    pub scopes: Vec<CleanupScopeReport>,
    pub total_removed: usize,
    pub total_kept: usize,
    pub total_bytes_reclaimed: u64,
}

#[derive(Clone, Debug, Serialize)]
pub struct DependentPackageReport {
    pub package_name: String,
    pub install_reason: String,
    pub world_member: bool,
    pub direct: bool,
    pub depth: usize,
}

#[derive(Clone, Debug, Serialize)]
pub struct DependentsReport {
    pub package_name: String,
    pub transitive: bool,
    pub packages: Vec<DependentPackageReport>,
}

#[derive(Clone, Debug, Serialize)]
pub struct CacheStatusReport {
    pub package_name: String,
    pub version: String,
    pub status: String,
    pub recipe_hash: String,
    pub archive_path: Option<PathBuf>,
    pub archive_sha256: Option<String>,
    pub build_transaction_id: Option<i64>,
}

#[derive(Clone, Debug, Serialize)]
pub struct TransactionPackageReport {
    pub package_name: String,
    pub version: String,
    pub action: String,
    pub install_reason: Option<String>,
    pub archive_path: Option<PathBuf>,
    pub archive_sha256: Option<String>,
    pub entries: usize,
}

#[derive(Clone, Debug, Serialize)]
pub struct TransactionReport {
    pub transaction_id: i64,
    pub operation: String,
    pub requested_packages: Vec<String>,
    pub target_root: PathBuf,
    pub packages: Vec<TransactionPackageReport>,
}

#[derive(Clone, Debug)]
struct PreparedInstall {
    package_name: String,
    version: String,
    install_reason: String,
    action: String,
    cached: CachedBinaryPackage,
    manifest: PackageManifest,
}

#[derive(Clone, Debug)]
struct PreparedRemoval {
    package: InstalledPackageRecord,
    action: String,
}

#[derive(Clone, Debug)]
struct BootstrapPlan {
    package_name: String,
    sysroot: String,
    stages: Vec<BootstrapStagePlan>,
}

#[derive(Clone, Debug)]
struct BootstrapStagePlan {
    name: String,
    packages: Vec<PackageRecord>,
    env: Vec<(String, String)>,
}

#[derive(Clone, Debug)]
struct BootstrapProgress {
    total_stages: usize,
    total_packages: usize,
    completed_stages: usize,
    completed_packages: usize,
}

#[derive(Clone, Copy, Debug)]
enum SnapshotLoadMode {
    Strict,
    BestEffort,
}

pub struct App {
    pub paths: AppPaths,
}

impl App {
    pub fn new(paths: AppPaths) -> Self {
        Self { paths }
    }

    pub fn init(&self, recipe_root: Option<&Path>) -> Result<(), AppError> {
        self.paths.create_layout()?;
        init_db(&self.paths.database_path)?;

        let mut repos = self.load_repo_config()?;
        if repos.repo.is_empty() {
            if let Some(path) = recipe_root {
                repos.repo.push(local_recipe_repo(path));
            }
            self.save_repo_config(&repos)?;
        }

        Ok(())
    }

    pub fn add_repo(&self, repo: RepoConfigEntry) -> Result<(), AppError> {
        self.paths.create_layout()?;
        let mut config = self.load_repo_config()?;
        if let Some(existing) = config.repo.iter_mut().find(|entry| entry.name == repo.name) {
            *existing = repo;
        } else {
            config.repo.push(repo);
        }
        self.save_repo_config(&config)?;
        Ok(())
    }

    pub fn list_repos(&self, recipe_root: Option<&Path>) -> Result<Vec<RepoSummary>, AppError> {
        let mut repos = self.load_repo_config()?.repo;
        if repos.is_empty() {
            if let Some(path) = recipe_root {
                repos.push(local_recipe_repo(path));
            }
        }

        Ok(repos
            .into_iter()
            .map(|repo| RepoSummary {
                name: repo.name,
                kind: match repo.kind {
                    RepoKind::Recipe => String::from("recipe"),
                    RepoKind::Binary => String::from("binary"),
                    RepoKind::Unified => String::from("unified"),
                },
                url: repo.url,
                channel: repo.channel,
                priority: repo.priority,
                enabled: repo.enabled,
                trust_policy: format_repo_trust_mode(repo.trust_policy).to_owned(),
                sync_strategy: format_repo_sync_strategy(repo.sync_strategy).to_owned(),
            })
            .collect())
    }

    pub fn update(
        &self,
        recipe_root: Option<&Path>,
        repo_name: Option<&str>,
    ) -> Result<UpdateReport, AppError> {
        self.paths.create_layout()?;
        init_db(&self.paths.database_path)?;

        let mut repos = self.load_repo_config()?.repo;
        if repos.is_empty() {
            if let Some(path) = recipe_root {
                repos.push(local_recipe_repo(path));
            }
        }

        if let Some(name) = repo_name {
            if !repos.iter().any(|repo| repo.name == name) {
                return Err(AppError::UnknownRepository(name.to_owned()));
            }
        }

        let reports = repos
            .into_iter()
            .filter(|repo| repo.enabled)
            .filter(|repo| repo_name.map(|name| repo.name == name).unwrap_or(true))
            .map(|repo| match repo.kind {
                RepoKind::Unified => self
                    .update_unified_repo(&repo)
                    .map(|report| map_unified_update_report(&repo.name, report)),
                RepoKind::Recipe => Ok(UpdateRepoReport {
                    name: repo.name,
                    kind: String::from("recipe"),
                    action: String::from("skipped"),
                    channel: repo.channel,
                    revision: None,
                    snapshot_root: Some(PathBuf::from(repo.url)),
                    package_count: 0,
                    file_count: 0,
                }),
                RepoKind::Binary => Ok(UpdateRepoReport {
                    name: repo.name,
                    kind: String::from("binary"),
                    action: String::from("skipped"),
                    channel: repo.channel,
                    revision: None,
                    snapshot_root: None,
                    package_count: 0,
                    file_count: 0,
                }),
            })
            .collect::<Result<Vec<_>, AppError>>()?;

        Ok(UpdateReport { repos: reports })
    }

    pub fn export_repo(
        &self,
        recipe_root: Option<&Path>,
        output_root: &Path,
        channel: &str,
        revision: Option<&str>,
    ) -> Result<RepoExportReport, AppError> {
        let recipe_root = recipe_root.ok_or(AppError::MissingRecipeRoot)?;
        let report = export_unified_recipe_repo(recipe_root, output_root, channel, revision)?;
        Ok(map_repo_export_report(report))
    }

    pub fn publish_repo(
        &self,
        recipe_root: Option<&Path>,
        repo_name_override: Option<&str>,
        channel: &str,
        revision: Option<&str>,
        keep_revisions: usize,
    ) -> Result<RepoPublishReport, AppError> {
        self.publish_repo_with_options(
            recipe_root,
            repo_name_override,
            channel,
            revision,
            keep_revisions,
            RepoPublishOptions::default(),
        )
    }

    pub fn publish_repo_with_options(
        &self,
        recipe_root: Option<&Path>,
        repo_name_override: Option<&str>,
        channel: &str,
        revision: Option<&str>,
        keep_revisions: usize,
        options: RepoPublishOptions,
    ) -> Result<RepoPublishReport, AppError> {
        self.paths.create_layout()?;
        let recipe_root = recipe_root.ok_or(AppError::MissingRecipeRoot)?;
        let temp_root = self
            .paths
            .published_repos_dir
            .join(format!(".publish-tmp-{}", publish_revision_string()));
        if temp_root.exists() {
            fs::remove_dir_all(&temp_root).map_err(|source| AppError::Io {
                path: temp_root.clone(),
                source,
            })?;
        }
        let revision_name = revision
            .map(str::to_owned)
            .unwrap_or_else(publish_revision_string);
        let export =
            export_unified_recipe_repo(recipe_root, &temp_root, channel, Some(&revision_name))?;
        let repo_name = repo_name_override
            .map(str::to_owned)
            .unwrap_or_else(|| export.repo_name.clone());
        let repo_root = self.published_repo_root(&repo_name);
        let revisions_root = repo_root.join("revisions").join(sanitize(channel));
        fs::create_dir_all(&revisions_root).map_err(|source| AppError::Io {
            path: revisions_root.clone(),
            source,
        })?;
        let published_root = revisions_root.join(sanitize(&revision_name));
        if published_root.exists() {
            fs::remove_dir_all(&published_root).map_err(|source| AppError::Io {
                path: published_root.clone(),
                source,
            })?;
        }
        fs::rename(&temp_root, &published_root).map_err(|source| AppError::Io {
            path: published_root.clone(),
            source,
        })?;

        let live_root = repo_root.join("live");
        if path_exists(&live_root) {
            remove_existing_path(&live_root)?;
        }
        symlink(&published_root, &live_root).map_err(|source| AppError::Io {
            path: live_root.clone(),
            source,
        })?;

        self.write_publish_state(
            &repo_name,
            &PublishState {
                repo_name: repo_name.clone(),
                source_root: recipe_root.display().to_string(),
                channel: channel.to_owned(),
                keep_revisions,
                remember: options.remember_publish_state,
            },
        )?;

        Ok(RepoPublishReport {
            repo_name,
            source_root: recipe_root.to_path_buf(),
            channel: export.channel,
            revision: export.revision,
            published_root,
            live_root,
            package_count: export.package_count,
            version_count: export.version_count,
            file_count: export.file_count,
            keep_revisions,
        })
    }

    pub fn promote_repo(
        &self,
        source_repo_name: &str,
        source_channel: &str,
        source_revision: Option<&str>,
        target_repo_name: &str,
        target_channel: &str,
        keep_revisions: usize,
    ) -> Result<RepoPromoteReport, AppError> {
        self.paths.create_layout()?;
        let source_state = self
            .read_publish_state(source_repo_name)?
            .ok_or_else(|| AppError::MissingPublishState(source_repo_name.to_owned()))?;
        let source_repo_root = self.published_repo_root(source_repo_name);
        let (resolved_source_revision, source_published_root) = if let Some(revision_name) =
            source_revision
        {
            let root = source_repo_root
                .join("revisions")
                .join(sanitize(source_channel))
                .join(sanitize(revision_name));
            if !root.exists() {
                return Err(AppError::MissingPublishedRevision {
                    repo: source_repo_name.to_owned(),
                    channel: source_channel.to_owned(),
                    revision: revision_name.to_owned(),
                });
            }
            (revision_name.to_owned(), root)
        } else {
            let live_root = source_repo_root.join("live");
            if !path_exists(&live_root) {
                return Err(AppError::MissingPublishedLiveRevision {
                    repo: source_repo_name.to_owned(),
                    channel: source_channel.to_owned(),
                });
            }
            let canonical = normalize_existing_path(&live_root);
            let expected_prefix = source_repo_root.join("revisions").join(sanitize(source_channel));
            if !canonical.starts_with(&expected_prefix) {
                return Err(AppError::MissingPublishedLiveRevision {
                    repo: source_repo_name.to_owned(),
                    channel: source_channel.to_owned(),
                });
            }
            let revision_name = canonical
                .file_name()
                .map(|value| value.to_string_lossy().to_string())
                .ok_or_else(|| AppError::MissingPublishedLiveRevision {
                    repo: source_repo_name.to_owned(),
                    channel: source_channel.to_owned(),
                })?;
            (revision_name, canonical)
        };

        let target_repo_root = self.published_repo_root(target_repo_name);
        let target_revisions_root = target_repo_root.join("revisions").join(sanitize(target_channel));
        fs::create_dir_all(&target_revisions_root).map_err(|source| AppError::Io {
            path: target_revisions_root.clone(),
            source,
        })?;
        let target_published_root = target_revisions_root.join(sanitize(&resolved_source_revision));
        if target_published_root.exists() {
            fs::remove_dir_all(&target_published_root).map_err(|source| AppError::Io {
                path: target_published_root.clone(),
                source,
            })?;
        }
        copy_tree_into(&source_published_root, &target_published_root)?;

        let target_live_root = target_repo_root.join("live");
        if path_exists(&target_live_root) {
            remove_existing_path(&target_live_root)?;
        }
        symlink(&target_published_root, &target_live_root).map_err(|source| AppError::Io {
            path: target_live_root.clone(),
            source,
        })?;

        self.write_publish_state(
            target_repo_name,
            &PublishState {
                repo_name: target_repo_name.to_owned(),
                source_root: source_state.source_root,
                channel: target_channel.to_owned(),
                keep_revisions,
                remember: true,
            },
        )?;

        Ok(RepoPromoteReport {
            source_repo_name: source_repo_name.to_owned(),
            source_channel: source_channel.to_owned(),
            source_revision: resolved_source_revision.clone(),
            source_published_root,
            target_repo_name: target_repo_name.to_owned(),
            target_channel: target_channel.to_owned(),
            target_revision: resolved_source_revision,
            target_published_root,
            target_live_root,
            keep_revisions,
        })
    }

    pub fn cleanup(&self, target: CleanupTarget) -> Result<CleanupReport, AppError> {
        self.paths.create_layout()?;
        init_db(&self.paths.database_path)?;

        let scopes = match target {
            CleanupTarget::Builds => vec![self.cleanup_builds()?],
            CleanupTarget::Repos => vec![self.cleanup_repo_snapshots()?],
            CleanupTarget::Published => vec![self.cleanup_published_revisions()?],
            CleanupTarget::All => vec![
                self.cleanup_builds()?,
                self.cleanup_repo_snapshots()?,
                self.cleanup_published_revisions()?,
            ],
        };
        let total_removed = scopes.iter().map(|scope| scope.removed.len()).sum();
        let total_kept = scopes.iter().map(|scope| scope.kept.len()).sum();
        let total_bytes_reclaimed = scopes.iter().map(|scope| scope.bytes_reclaimed).sum();

        Ok(CleanupReport {
            target: format_cleanup_target(target).to_owned(),
            scopes,
            total_removed,
            total_kept,
            total_bytes_reclaimed,
        })
    }

    pub fn resolve(
        &self,
        recipe_root: Option<&Path>,
        package_name: &str,
        constraint: &str,
    ) -> Result<TransactionPlan, AppError> {
        self.resolve_many(recipe_root, &[package_name.to_owned()], constraint)
    }

    pub fn resolve_many(
        &self,
        recipe_root: Option<&Path>,
        package_names: &[String],
        constraint: &str,
    ) -> Result<TransactionPlan, AppError> {
        let parsed = Constraint::parse(constraint)?;
        let requests = package_names
            .iter()
            .map(|package_name| RequestedPackage {
                name: package_name.clone(),
                constraint: parsed.clone(),
            })
            .collect::<Vec<_>>();
        self.resolve_requests(recipe_root, &requests)
    }

    fn resolve_requests(
        &self,
        recipe_root: Option<&Path>,
        requests: &[RequestedPackage],
    ) -> Result<TransactionPlan, AppError> {
        let packages = self.load_packages(recipe_root)?;
        solve(&packages, requests, &SolveOptions::default()).map_err(AppError::from)
    }

    pub fn dependents(
        &self,
        package_name: &str,
        transitive: bool,
    ) -> Result<DependentsReport, AppError> {
        self.paths.create_layout()?;
        init_db(&self.paths.database_path)?;

        let installed = installed_package_map(list_installed_packages(&self.paths.database_path)?);
        if !installed.contains_key(package_name) {
            return Err(AppError::PackageNotInstalled(package_name.to_owned()));
        }
        let world_names = list_world_entries(&self.paths.database_path)?
            .into_iter()
            .map(|entry| entry.package_name)
            .collect::<HashSet<_>>();
        let mut dependents_by_dependency = BTreeMap::<String, BTreeSet<String>>::new();
        for edge in list_installed_dependencies(&self.paths.database_path)? {
            dependents_by_dependency
                .entry(edge.dependency_name)
                .or_default()
                .insert(edge.package_name);
        }

        let direct_dependents = dependents_by_dependency
            .get(package_name)
            .cloned()
            .unwrap_or_default();
        let mut seen = HashSet::new();
        let mut queue = VecDeque::new();
        for dependent in direct_dependents {
            queue.push_back((dependent, 1usize));
        }

        let mut packages = Vec::new();
        while let Some((dependent, depth)) = queue.pop_front() {
            if !seen.insert(dependent.clone()) {
                continue;
            }
            let Some(installed_record) = installed.get(&dependent) else {
                continue;
            };
            packages.push(DependentPackageReport {
                package_name: dependent.clone(),
                install_reason: installed_record.install_reason.clone(),
                world_member: world_names.contains(&dependent),
                direct: depth == 1,
                depth,
            });

            if !transitive {
                continue;
            }
            if let Some(next_dependents) = dependents_by_dependency.get(&dependent) {
                for next in next_dependents {
                    if !seen.contains(next) {
                        queue.push_back((next.clone(), depth + 1));
                    }
                }
            }
        }

        Ok(DependentsReport {
            package_name: package_name.to_owned(),
            transitive,
            packages,
        })
    }

    pub fn cache_status(
        &self,
        recipe_root: Option<&Path>,
        package_name: &str,
        constraint: &str,
    ) -> Result<CacheStatusReport, AppError> {
        self.paths.create_layout()?;
        init_db(&self.paths.database_path)?;

        let plan = self.resolve(recipe_root, package_name, constraint)?;
        let selected = plan
            .packages
            .iter()
            .find(|planned| planned.package.package.name == package_name)
            .map(|planned| planned.package.clone())
            .ok_or_else(|| AppError::MissingRequestedPackage(package_name.to_owned()))?;
        let recipe_hash = recipe_source_hash(&selected)?;
        let arch = selected
            .package
            .architectures
            .first()
            .cloned()
            .unwrap_or_else(|| String::from("any"));
        let records = find_cache_packages(
            &self.paths.database_path,
            &selected.package.name,
            selected.package.evr.epoch,
            &selected.package.evr.version,
            &selected.package.evr.release,
            &arch,
        )?;

        let mut available_record = None;
        let mut matching_record = None;
        for record in records {
            if !Path::new(&record.archive_path).exists() {
                continue;
            }
            if available_record.is_none() {
                available_record = Some(record.clone());
            }
            if record.recipe_hash.as_deref() == Some(recipe_hash.as_str()) {
                matching_record = Some(record);
                break;
            }
        }

        let selected_record = matching_record.clone().or_else(|| available_record.clone());
        let status = if matching_record.is_some() {
            "ready"
        } else if available_record.is_some() {
            "stale"
        } else {
            "missing"
        };

        Ok(CacheStatusReport {
            package_name: selected.package.name.clone(),
            version: selected.package.evr.to_string(),
            status: status.to_owned(),
            recipe_hash,
            archive_path: selected_record
                .as_ref()
                .map(|record| PathBuf::from(record.archive_path.clone())),
            archive_sha256: selected_record
                .as_ref()
                .map(|record| record.checksum.clone()),
            build_transaction_id: selected_record.map(|record| record.build_transaction_id),
        })
    }

    pub fn fetch(
        &self,
        recipe_root: Option<&Path>,
        package_name: &str,
        constraint: &str,
    ) -> Result<FetchReport, AppError> {
        self.paths.create_layout()?;
        init_db(&self.paths.database_path)?;

        let packages = self.load_packages(recipe_root)?;
        let request = RequestedPackage {
            name: package_name.to_owned(),
            constraint: Constraint::parse(constraint)?,
        };
        let plan = solve(
            &packages,
            &[request],
            &SolveOptions {
                include_build_dependencies: true,
                include_optional_dependencies: false,
            },
        )?;

        let mut package_reports = Vec::new();
        let mut downloaded = 0usize;
        let mut cached = 0usize;
        let mut local = 0usize;
        let mut bytes_downloaded = 0u64;

        for planned in plan.packages {
            let report = fetch_package_sources(&planned.package, &self.paths.distfiles_dir)?;
            for entry in &report.entries {
                match entry.action.as_str() {
                    "downloaded" => {
                        downloaded += 1;
                        bytes_downloaded += entry.size.unwrap_or(0);
                    }
                    "cached" => cached += 1,
                    "local" => local += 1,
                    _ => {}
                }
                if entry.action != "local" {
                    if let Some(local_path) = &entry.local_path {
                        record_distfile(
                            &self.paths.database_path,
                            &DistfileRecord {
                                source_url: entry.source_url.clone(),
                                local_filename: local_path.display().to_string(),
                                checksum: entry
                                    .checksum
                                    .clone()
                                    .unwrap_or_else(|| String::from("local")),
                                size: entry.size,
                                fetch_source: Some(String::from("sloppkg fetch")),
                            },
                        )?;
                    }
                }
            }
            package_reports.push(report);
        }

        Ok(FetchReport {
            packages: package_reports,
            downloaded,
            cached,
            local,
            bytes_downloaded,
        })
    }

    pub fn build(
        &self,
        recipe_root: Option<&Path>,
        package_name: &str,
        constraint: &str,
    ) -> Result<BuildReport, AppError> {
        self.paths.create_layout()?;
        init_db(&self.paths.database_path)?;

        let packages = self.load_packages(recipe_root)?;
        let request = RequestedPackage {
            name: package_name.to_owned(),
            constraint: Constraint::parse(constraint)?,
        };
        let plan = solve(
            &packages,
            &[request.clone()],
            &SolveOptions {
                include_build_dependencies: true,
                include_optional_dependencies: false,
            },
        )?;
        let selected = plan
            .packages
            .iter()
            .find(|planned| planned.package.package.name == package_name)
            .map(|planned| planned.package.clone())
            .ok_or_else(|| AppError::MissingRequestedPackage(package_name.to_owned()))?;

        let requested_json = serde_json::to_string_pretty(&json!({
            "package": package_name,
            "constraint": constraint,
            "operation": "build-package"
        }))?;
        let actions = plan
            .packages
            .iter()
            .map(|planned| TransactionActionRecord {
                action_kind: if planned.package.package.name == package_name {
                    String::from("build-package")
                } else {
                    String::from("resolve")
                },
                package_name: planned.package.package.name.clone(),
                version_text: planned.package.package.evr.to_string(),
                reason: planned.reason.clone(),
            })
            .collect::<Vec<_>>();
        let transaction_id = create_transaction(
            &self.paths.database_path,
            "build-package",
            &requested_json,
            &actions,
        )?;
        update_transaction_status(&self.paths.database_path, transaction_id, "building")?;
        let log_path = self.build_log_path(transaction_id, &selected.package.name);

        let build_result = stage_package(
            &selected,
            &self.paths.distfiles_dir,
            &self.paths.build_dir,
            &self.paths.packages_dir,
            transaction_id,
            &log_path,
            &[],
        );

        match build_result {
            Ok(report) => {
                let recipe_hash = recipe_source_hash(&selected)?;
                record_cache_package(
                    &self.paths.database_path,
                    &CachePackageRecord {
                        name: selected.package.name.clone(),
                        epoch: selected.package.evr.epoch,
                        version: selected.package.evr.version.clone(),
                        release: selected.package.evr.release.clone(),
                        arch: selected
                            .package
                            .architectures
                            .first()
                            .cloned()
                            .unwrap_or_else(|| String::from("any")),
                        archive_path: report.package_archive_path.display().to_string(),
                        checksum: report.package_archive_sha256.clone(),
                        recipe_hash: Some(recipe_hash),
                        build_transaction_id: transaction_id,
                    },
                )?;
                let repo_index = generate_binary_repo_index(&self.paths.packages_dir, None)?;
                let transaction_path = self
                    .paths
                    .transactions_dir
                    .join(format!("{transaction_id}.json"));
                let transaction_json = serde_json::to_vec_pretty(&json!({
                    "transaction_id": transaction_id,
                    "operation": "build-package",
                    "requested": {
                        "package": package_name,
                        "constraint": constraint,
                    },
                    "resolved_packages": plan.packages.iter().map(|planned| json!({
                        "name": planned.package.package.name,
                        "version": planned.package.package.evr.to_string(),
                        "repo": planned.package.repo_name,
                        "reason": planned.reason,
                    })).collect::<Vec<_>>(),
                    "repo_index": &repo_index,
                    "build_report": &report,
                }))?;
                fs::write(&transaction_path, transaction_json).map_err(|source| AppError::Io {
                    path: transaction_path,
                    source,
                })?;
                update_transaction_status(&self.paths.database_path, transaction_id, "packaged")?;
                Ok(report)
            }
            Err(err) => {
                let transaction_path = self
                    .paths
                    .transactions_dir
                    .join(format!("{transaction_id}.json"));
                let transaction_json = serde_json::to_vec_pretty(&json!({
                    "transaction_id": transaction_id,
                    "operation": "build-package",
                    "requested": {
                        "package": package_name,
                        "constraint": constraint,
                    },
                    "status": "failed",
                    "log_path": log_path,
                    "error": err.to_string(),
                }))?;
                fs::write(&transaction_path, transaction_json).map_err(|source| AppError::Io {
                    path: transaction_path,
                    source,
                })?;
                let _ =
                    update_transaction_status(&self.paths.database_path, transaction_id, "failed");
                Err(AppError::from(err))
            }
        }
    }

    pub fn doctor(&self, recipe_root: Option<&Path>) -> Result<DoctorReport, AppError> {
        self.paths.create_layout()?;
        init_db(&self.paths.database_path)?;
        check_db(&self.paths.database_path)?;
        let repo_count = self.list_repos(recipe_root)?.len();
        let repos = self.load_snapshots(recipe_root, SnapshotLoadMode::BestEffort)?;
        let packages_loaded = repos.iter().map(|repo| repo.packages.len()).sum::<usize>();

        Ok(DoctorReport {
            state_root: self.paths.state_root.clone(),
            database_path: self.paths.database_path.clone(),
            repo_count,
            packages_loaded,
            status: String::from("ok"),
        })
    }

    pub fn install(
        &self,
        recipe_root: Option<&Path>,
        package_name: &str,
        constraint: &str,
        target_root: &Path,
    ) -> Result<TransactionReport, AppError> {
        self.install_with_options(
            recipe_root,
            package_name,
            constraint,
            target_root,
            TransactionOptions::default(),
        )
    }

    pub fn install_with_options(
        &self,
        recipe_root: Option<&Path>,
        package_name: &str,
        constraint: &str,
        target_root: &Path,
        options: TransactionOptions,
    ) -> Result<TransactionReport, AppError> {
        self.paths.create_layout()?;
        init_db(&self.paths.database_path)?;

        let packages = self.load_packages(recipe_root)?;
        let request = RequestedPackage {
            name: package_name.to_owned(),
            constraint: Constraint::parse(constraint)?,
        };
        let plan = solve(
            &packages,
            &[request.clone()],
            &SolveOptions {
                include_build_dependencies: false,
                include_optional_dependencies: false,
            },
        )?;
        let requested_names = HashSet::from([package_name.to_owned()]);
        self.run_requested_bootstraps(&packages, &plan, &requested_names, target_root)?;
        let installed = installed_package_map(list_installed_packages(&self.paths.database_path)?);
        let prepared = self.prepare_install_operations(&plan, &requested_names, &installed)?;
        let report = self.execute_transaction(
            "install-cache",
            vec![package_name.to_owned()],
            target_root,
            &prepared,
            &[],
            json!({
                "operation": "install-cache",
                "requested": [{
                    "package": package_name,
                    "constraint": constraint,
                }],
                "resolved_packages": plan.packages.iter().map(|planned| json!({
                    "name": planned.package.package.name,
                    "version": planned.package.package.evr.to_string(),
                    "reason": planned.reason,
                })).collect::<Vec<_>>(),
            }),
        )?;
        upsert_world_entry(&self.paths.database_path, package_name, constraint)?;
        self.finalize_transaction(report, target_root, options)
    }

    pub fn remove(
        &self,
        package_name: &str,
        target_root: &Path,
    ) -> Result<TransactionReport, AppError> {
        self.remove_with_options(package_name, target_root, TransactionOptions::default())
    }

    pub fn remove_with_options(
        &self,
        package_name: &str,
        target_root: &Path,
        options: TransactionOptions,
    ) -> Result<TransactionReport, AppError> {
        self.paths.create_layout()?;
        init_db(&self.paths.database_path)?;

        let installed = installed_package_map(list_installed_packages(&self.paths.database_path)?);
        let installed_record = installed
            .get(package_name)
            .cloned()
            .ok_or_else(|| AppError::PackageNotInstalled(package_name.to_owned()))?;
        let world_entries = list_world_entries(&self.paths.database_path)?;
        let remaining_world = world_entries
            .iter()
            .filter(|entry| entry.package_name != package_name)
            .cloned()
            .collect::<Vec<_>>();
        let dependencies = list_installed_dependencies(&self.paths.database_path)?;
        let removal =
            compute_removal_plan(package_name, &installed, &remaining_world, &dependencies)?;
        let report = self.execute_transaction(
            "remove",
            vec![package_name.to_owned()],
            target_root,
            &[],
            &removal,
            json!({
                "operation": "remove",
                "requested": [{
                    "package": package_name,
                    "installed_version": format_evr_parts(installed_record.epoch, &installed_record.version, &installed_record.release),
                }],
                "remove_packages": removal.iter().map(|package| json!({
                    "name": package.package.name,
                    "version": format_evr_parts(package.package.epoch, &package.package.version, &package.package.release),
                    "action": package.action,
                })).collect::<Vec<_>>(),
            }),
        )?;
        remove_world_entry(&self.paths.database_path, package_name)?;
        self.finalize_transaction(report, target_root, options)
    }

    pub fn upgrade(
        &self,
        recipe_root: Option<&Path>,
        target_root: &Path,
    ) -> Result<TransactionReport, AppError> {
        self.upgrade_with_options(recipe_root, target_root, TransactionOptions::default())
    }

    pub fn upgrade_with_options(
        &self,
        recipe_root: Option<&Path>,
        target_root: &Path,
        options: TransactionOptions,
    ) -> Result<TransactionReport, AppError> {
        self.paths.create_layout()?;
        init_db(&self.paths.database_path)?;

        let world_entries = list_world_entries(&self.paths.database_path)?;
        if world_entries.is_empty() {
            return Err(AppError::NoWorldPackages);
        }

        let packages = self.load_packages(recipe_root)?;
        let requests = world_entries
            .iter()
            .map(|entry| {
                Ok(RequestedPackage {
                    name: entry.package_name.clone(),
                    constraint: Constraint::parse(&entry.constraint_text)?,
                })
            })
            .collect::<Result<Vec<_>, AppError>>()?;
        let plan = solve(
            &packages,
            &requests,
            &SolveOptions {
                include_build_dependencies: false,
                include_optional_dependencies: false,
            },
        )?;
        let installed = installed_package_map(list_installed_packages(&self.paths.database_path)?);
        let requested_names = world_entries
            .iter()
            .map(|entry| entry.package_name.clone())
            .collect::<HashSet<_>>();
        self.run_requested_bootstraps(&packages, &plan, &requested_names, target_root)?;
        let prepared = self.prepare_install_operations(&plan, &requested_names, &installed)?;
        let selected_names = plan
            .packages
            .iter()
            .map(|planned| planned.package.package.name.clone())
            .collect::<HashSet<_>>();
        let removals = installed
            .values()
            .filter(|package| package.install_reason == "auto")
            .filter(|package| !selected_names.contains(&package.name))
            .map(|package| PreparedRemoval {
                package: package.clone(),
                action: String::from("autoremove"),
            })
            .collect::<Vec<_>>();
        let report = self.execute_transaction(
            "upgrade",
            requested_names.iter().cloned().collect(),
            target_root,
            &prepared,
            &removals,
            json!({
                "operation": "upgrade",
                "requested": world_entries.iter().map(|entry| json!({
                    "package": entry.package_name,
                    "constraint": entry.constraint_text,
                })).collect::<Vec<_>>(),
                "resolved_packages": plan.packages.iter().map(|planned| json!({
                    "name": planned.package.package.name,
                    "version": planned.package.package.evr.to_string(),
                    "reason": planned.reason,
                })).collect::<Vec<_>>(),
            }),
        )?;
        self.finalize_transaction(report, target_root, options)
    }

    pub fn index_binary_repo(
        &self,
        repo_name_override: Option<&str>,
    ) -> Result<BinaryRepoIndexReport, AppError> {
        self.paths.create_layout()?;
        Ok(generate_binary_repo_index(
            &self.paths.packages_dir,
            repo_name_override,
        )?)
    }

    pub fn format_plan(plan: &TransactionPlan) -> String {
        let mut output = String::new();
        for package in &plan.packages {
            let _ = writeln!(
                output,
                "- {} {} [{}] ({})",
                package.package.package.name,
                package.package.package.evr,
                package.package.repo_name,
                package.reason
            );
        }
        output
    }

    pub fn format_build_report(report: &BuildReport) -> String {
        format!(
            "staged {} {}\ntransaction: {}\nlog: {}\nwork_dir: {}\nstage_root: {}\nmanifest: {}\narchive: {}\narchive_sha256: {}\narchive_size: {}\nentries: {}\n",
            report.package_name,
            report.version,
            report.transaction_id,
            report.log_path.display(),
            report.work_dir.display(),
            report.stage_root.display(),
            report.manifest_path.display(),
            report.package_archive_path.display(),
            report.package_archive_sha256,
            report.package_archive_size,
            report.manifest_entries,
        )
    }

    pub fn format_cache_status_report(report: &CacheStatusReport) -> String {
        let mut output = String::new();
        let _ = writeln!(
            output,
            "cache {} {} {}",
            report.status, report.package_name, report.version
        );
        let _ = writeln!(output, "recipe_hash: {}", report.recipe_hash);
        if let Some(archive_path) = &report.archive_path {
            let _ = writeln!(output, "archive: {}", archive_path.display());
        }
        if let Some(archive_sha256) = &report.archive_sha256 {
            let _ = writeln!(output, "archive_sha256: {archive_sha256}");
        }
        if let Some(transaction_id) = report.build_transaction_id {
            let _ = writeln!(output, "transaction: {transaction_id}");
        }
        output
    }

    fn build_log_path(&self, transaction_id: i64, package_name: &str) -> PathBuf {
        self.paths.logs_dir.join("builds").join(format!(
            "{transaction_id}-{}.log",
            sanitize_log_name(package_name)
        ))
    }

    pub fn format_repo_index_report(report: &BinaryRepoIndexReport) -> String {
        format!(
            "indexed {} package(s)\nrepo: {}\nrepo_root: {}\nrepo_toml: {}\nindex: {}\narchitectures: {}\n",
            report.package_count,
            report.repo_name,
            report.repo_root.display(),
            report.repo_toml_path.display(),
            report.index_path.display(),
            if report.architectures.is_empty() {
                String::from("(none)")
            } else {
                report.architectures.join(", ")
            },
        )
    }

    pub fn format_update_report(report: &UpdateReport) -> String {
        let mut output = String::new();
        for repo in &report.repos {
            let _ = writeln!(
                output,
                "- {} [{}] {}{}{} packages={} files={}",
                repo.name,
                repo.kind,
                repo.action,
                repo.channel
                    .as_deref()
                    .map(|channel| format!(" channel={channel}"))
                    .unwrap_or_default(),
                repo.revision
                    .as_deref()
                    .map(|revision| format!(" revision={revision}"))
                    .unwrap_or_default(),
                repo.package_count,
                repo.file_count,
            );
            if let Some(snapshot_root) = &repo.snapshot_root {
                let _ = writeln!(output, "  snapshot: {}", snapshot_root.display());
            }
        }
        output
    }

    pub fn format_fetch_report(report: &FetchReport) -> String {
        let mut output = format!(
            "fetch\npackages: {}\ndownloaded: {}\ncached: {}\nlocal: {}\nbytes_downloaded: {}\n",
            report.packages.len(),
            report.downloaded,
            report.cached,
            report.local,
            format_byte_count(report.bytes_downloaded),
        );
        for package in &report.packages {
            let _ = writeln!(
                output,
                "- {} {} sources={}",
                package.package_name,
                package.version,
                package.entries.len()
            );
            for entry in &package.entries {
                let _ = writeln!(
                    output,
                    "  {} {}{}{}",
                    entry.action,
                    entry.source_url,
                    entry
                        .local_path
                        .as_ref()
                        .map(|path| format!(" -> {}", path.display()))
                        .unwrap_or_default(),
                    entry
                        .size
                        .map(|size| format!(" ({})", format_byte_count(size)))
                        .unwrap_or_default(),
                );
            }
        }
        output
    }

    pub fn format_dependents_report(report: &DependentsReport) -> String {
        let mut output = format!(
            "dependents for {}\ntransitive: {}\npackages: {}\n",
            report.package_name,
            if report.transitive { "yes" } else { "no" },
            report.packages.len()
        );
        for package in &report.packages {
            let _ = writeln!(
                output,
                "- {} depth={} direct={} install_reason={} world_member={}",
                package.package_name,
                package.depth,
                if package.direct { "yes" } else { "no" },
                package.install_reason,
                if package.world_member { "yes" } else { "no" },
            );
        }
        output
    }

    pub fn format_repo_export_report(report: &RepoExportReport) -> String {
        format!(
            "exported repo {}\nchannel: {}\nrevision: {}\noutput: {}\npackages: {}\nversions: {}\nfiles: {}\n",
            report.repo_name,
            report.channel,
            report.revision,
            report.output_root.display(),
            report.package_count,
            report.version_count,
            report.file_count,
        )
    }

    pub fn format_repo_publish_report(report: &RepoPublishReport) -> String {
        format!(
            "published repo {}\nchannel: {}\nrevision: {}\nsource: {}\npublished: {}\nlive: {}\npackages: {}\nversions: {}\nfiles: {}\nkeep_previous_revisions: {}\n",
            report.repo_name,
            report.channel,
            report.revision,
            report.source_root.display(),
            report.published_root.display(),
            report.live_root.display(),
            report.package_count,
            report.version_count,
            report.file_count,
            report.keep_revisions,
        )
    }

    pub fn format_repo_promote_report(report: &RepoPromoteReport) -> String {
        format!(
            "promoted repo revision\nsource_repo: {}\nsource_channel: {}\nsource_revision: {}\nsource_published: {}\ntarget_repo: {}\ntarget_channel: {}\ntarget_revision: {}\ntarget_published: {}\ntarget_live: {}\nkeep_previous_revisions: {}\n",
            report.source_repo_name,
            report.source_channel,
            report.source_revision,
            report.source_published_root.display(),
            report.target_repo_name,
            report.target_channel,
            report.target_revision,
            report.target_published_root.display(),
            report.target_live_root.display(),
            report.keep_revisions,
        )
    }

    pub fn format_cleanup_report(report: &CleanupReport) -> String {
        let mut output = format!(
            "cleanup {}\nremoved: {}\nkept: {}\nbytes_reclaimed: {}\n",
            report.target,
            report.total_removed,
            report.total_kept,
            format_byte_count(report.total_bytes_reclaimed),
        );
        for scope in &report.scopes {
            let _ = writeln!(
                output,
                "- {} removed={} kept={} reclaimed={}",
                scope.scope,
                scope.removed.len(),
                scope.kept.len(),
                format_byte_count(scope.bytes_reclaimed),
            );
            for entry in &scope.removed {
                let _ = writeln!(
                    output,
                    "  removed {} ({}, {})",
                    entry.path.display(),
                    format_byte_count(entry.bytes),
                    entry.reason,
                );
            }
            for entry in &scope.kept {
                let _ = writeln!(
                    output,
                    "  kept {} ({}, {})",
                    entry.path.display(),
                    format_byte_count(entry.bytes),
                    entry.reason,
                );
            }
        }
        output
    }

    pub fn format_transaction_report(report: &TransactionReport) -> String {
        let mut output = format!(
            "{} {} package(s)\ntransaction: {}\ntarget_root: {}\n",
            report.operation,
            report.packages.len(),
            report.transaction_id,
            report.target_root.display(),
        );
        for package in &report.packages {
            let _ = writeln!(
                output,
                "- {} {} [{}] entries={}",
                package.package_name, package.version, package.action, package.entries,
            );
        }
        output
    }

    fn plan_bootstrap(
        &self,
        packages: &[PackageRecord],
        bootstrap_package_name: &str,
        bootstrap: &BootstrapSpec,
    ) -> Result<BootstrapPlan, AppError> {
        if !bootstrap.sysroot.starts_with('/') {
            return Err(AppError::InvalidBootstrapMetadata {
                package: bootstrap_package_name.to_owned(),
                reason: String::from("bootstrap.sysroot must be an absolute path"),
            });
        }
        if bootstrap.stages.is_empty() {
            return Err(AppError::InvalidBootstrapMetadata {
                package: bootstrap_package_name.to_owned(),
                reason: String::from("bootstrap.stages must not be empty"),
            });
        }

        let package_names = packages
            .iter()
            .map(|package| package.package.name.clone())
            .collect::<HashSet<_>>();
        let mut stage_names = HashSet::new();
        let mut staged_packages = HashSet::new();
        for stage in &bootstrap.stages {
            if !stage_names.insert(stage.name.clone()) {
                return Err(AppError::DuplicateBootstrapStage {
                    package: bootstrap_package_name.to_owned(),
                    stage: stage.name.clone(),
                });
            }
            if stage.packages.is_empty() {
                return Err(AppError::InvalidBootstrapMetadata {
                    package: bootstrap_package_name.to_owned(),
                    reason: format!(
                        "bootstrap stage {} must declare at least one package",
                        stage.name
                    ),
                });
            }
            for package_name in &stage.packages {
                if !package_names.contains(package_name) {
                    return Err(AppError::UnknownBootstrapPackage {
                        package: bootstrap_package_name.to_owned(),
                        stage_package: package_name.clone(),
                    });
                }
                if !staged_packages.insert(package_name.clone()) {
                    return Err(AppError::DuplicateBootstrapStagePackage {
                        package: bootstrap_package_name.to_owned(),
                        stage_package: package_name.clone(),
                    });
                }
            }
        }

        let stage_name_set = bootstrap
            .stages
            .iter()
            .map(|stage| stage.name.clone())
            .collect::<HashSet<_>>();
        for stage in &bootstrap.stages {
            for dependency in &stage.depends_on {
                if !stage_name_set.contains(dependency) {
                    return Err(AppError::UnknownBootstrapStageDependency {
                        package: bootstrap_package_name.to_owned(),
                        stage_dependency: dependency.clone(),
                    });
                }
            }
        }

        let ordered_stage_names = topo_sort_stage_names(bootstrap_package_name, &bootstrap.stages)?;
        let stage_by_name = bootstrap
            .stages
            .iter()
            .map(|stage| (stage.name.clone(), stage))
            .collect::<HashMap<_, _>>();

        let mut stages = Vec::new();
        for stage_name in ordered_stage_names {
            let stage = stage_by_name
                .get(&stage_name)
                .expect("validated bootstrap stage exists");
            stages.push(BootstrapStagePlan {
                name: stage.name.clone(),
                packages: resolve_bootstrap_stage_packages(
                    packages,
                    bootstrap_package_name,
                    stage,
                )?,
                env: stage.env.clone(),
            });
        }

        Ok(BootstrapPlan {
            package_name: bootstrap_package_name.to_owned(),
            sysroot: bootstrap.sysroot.clone(),
            stages,
        })
    }

    fn run_bootstrap(&self, plan: &BootstrapPlan) -> Result<(), AppError> {
        let mut progress = BootstrapProgress::from_plan(plan);
        eprintln!(
            "bootstrap detected for {} (sysroot: {})",
            plan.package_name, plan.sysroot
        );
        eprintln!(
            "{}",
            format_bootstrap_progress(&progress, "starting bootstrap")
        );
        let stamp_root = self
            .paths
            .bootstrap_stamps_dir
            .join(sanitize(&plan.package_name));
        fs::create_dir_all(&stamp_root).map_err(|source| AppError::Io {
            path: stamp_root.clone(),
            source,
        })?;

        for stage in &plan.stages {
            let stamp_path = stamp_root.join(format!("{}.done", sanitize(&stage.name)));
            if self.bootstrap_stage_complete(stage, &stamp_path)? {
                progress.completed_stages += 1;
                progress.completed_packages += stage.packages.len();
                eprintln!(
                    "{}",
                    format_bootstrap_progress(
                        &progress,
                        &format!(
                            "stage {}/{} {} skipped",
                            progress.completed_stages, progress.total_stages, stage.name
                        ),
                    )
                );
                continue;
            }
            if stamp_path.exists() {
                fs::remove_file(&stamp_path).map_err(|source| AppError::Io {
                    path: stamp_path.clone(),
                    source,
                })?;
            }

            let mut seen_paths = BTreeMap::<String, String>::new();
            let next_stage_index = progress.completed_stages + 1;
            for (package_index, package) in stage.packages.iter().enumerate() {
                eprintln!(
                    "{}",
                    format_bootstrap_progress(
                        &progress,
                        &format!(
                            "stage {}/{} {} | package {}/{} {}",
                            next_stage_index,
                            progress.total_stages,
                            stage.name,
                            package_index + 1,
                            stage.packages.len(),
                            package.package.name
                        ),
                    )
                );
                let report = self.build_bootstrap_package(package, &stage.name, &stage.env)?;
                let manifest = read_manifest(&report.manifest_path)?;
                let manifest = installable_manifest(&manifest, &package.install.owned_prefixes)?;
                preflight_stage_manifest_paths(&manifest, &package.package.name, &mut seen_paths)?;
                copy_tree_into(&report.destdir, Path::new("/"))?;
                progress.completed_packages += 1;
                eprintln!(
                    "{}",
                    format_bootstrap_progress(
                        &progress,
                        &format!("built {} {}", package.package.name, package.package.evr),
                    )
                );
            }
            let stamp_contents = serde_json::to_vec_pretty(&json!({
                "package": plan.package_name,
                "stage": stage.name,
                "sysroot": plan.sysroot,
                "packages": stage.packages.iter().map(|package| json!({
                    "name": package.package.name,
                    "version": package.package.evr.to_string(),
                })).collect::<Vec<_>>(),
            }))?;
            fs::write(&stamp_path, stamp_contents).map_err(|source| AppError::Io {
                path: stamp_path.clone(),
                source,
            })?;
            progress.completed_stages += 1;
            eprintln!(
                "{}",
                format_bootstrap_progress(
                    &progress,
                    &format!(
                        "finished stage {}/{} {}",
                        progress.completed_stages, progress.total_stages, stage.name
                    ),
                )
            );
        }

        eprintln!(
            "{}",
            format_bootstrap_progress(
                &progress,
                &format!("bootstrap complete for {}", plan.package_name)
            )
        );
        Ok(())
    }

    fn bootstrap_stage_complete(
        &self,
        stage: &BootstrapStagePlan,
        stamp_path: &Path,
    ) -> Result<bool, AppError> {
        if !stamp_path.exists() {
            return Ok(false);
        }
        for package in &stage.packages {
            if !self.bootstrap_cached_package_ready(package)? {
                return Ok(false);
            }
        }
        Ok(true)
    }

    fn cleanup_builds(&self) -> Result<CleanupScopeReport, AppError> {
        let transaction_statuses = list_transaction_statuses(&self.paths.database_path)?
            .into_iter()
            .map(|record| (record.transaction_id, record.status))
            .collect::<HashMap<_, _>>();
        let mut removed = Vec::new();
        let mut kept = Vec::new();

        for entry in fs::read_dir(&self.paths.build_dir).map_err(|source| AppError::Io {
            path: self.paths.build_dir.clone(),
            source,
        })? {
            let entry = entry.map_err(|source| AppError::Io {
                path: self.paths.build_dir.clone(),
                source,
            })?;
            let path = entry.path();
            let file_type = entry.file_type().map_err(|source| AppError::Io {
                path: path.clone(),
                source,
            })?;
            if !file_type.is_dir() {
                continue;
            }

            let bytes = path_size(&path)?;
            let name = entry.file_name().to_string_lossy().into_owned();
            match transaction_id_from_work_dir_name(&name) {
                Some(transaction_id) => match transaction_statuses.get(&transaction_id) {
                    Some(status) if transaction_status_allows_cleanup(status) => {
                        fs::remove_dir_all(&path).map_err(|source| AppError::Io {
                            path: path.clone(),
                            source,
                        })?;
                        removed.push(CleanupEntryReport {
                            path,
                            bytes,
                            reason: format!("transaction {transaction_id} is {status}"),
                        });
                    }
                    Some(status) => kept.push(CleanupEntryReport {
                        path,
                        bytes,
                        reason: format!("transaction {transaction_id} is {status}"),
                    }),
                    None => {
                        fs::remove_dir_all(&path).map_err(|source| AppError::Io {
                            path: path.clone(),
                            source,
                        })?;
                        removed.push(CleanupEntryReport {
                            path,
                            bytes,
                            reason: format!("orphaned transaction {transaction_id}"),
                        });
                    }
                },
                None => kept.push(CleanupEntryReport {
                    path,
                    bytes,
                    reason: String::from("unrecognized build directory name"),
                }),
            }
        }

        Ok(CleanupScopeReport {
            scope: String::from("builds"),
            bytes_reclaimed: removed.iter().map(|entry| entry.bytes).sum(),
            removed,
            kept,
        })
    }

    fn cleanup_repo_snapshots(&self) -> Result<CleanupScopeReport, AppError> {
        let active_snapshots = self.active_unified_snapshot_roots()?;
        let mut removed = Vec::new();
        let mut kept = Vec::new();

        for repo_entry in
            fs::read_dir(&self.paths.repo_snapshots_dir).map_err(|source| AppError::Io {
                path: self.paths.repo_snapshots_dir.clone(),
                source,
            })?
        {
            let repo_entry = repo_entry.map_err(|source| AppError::Io {
                path: self.paths.repo_snapshots_dir.clone(),
                source,
            })?;
            let repo_path = repo_entry.path();
            let repo_type = repo_entry.file_type().map_err(|source| AppError::Io {
                path: repo_path.clone(),
                source,
            })?;
            if !repo_type.is_dir() {
                continue;
            }

            for channel_entry in fs::read_dir(&repo_path).map_err(|source| AppError::Io {
                path: repo_path.clone(),
                source,
            })? {
                let channel_entry = channel_entry.map_err(|source| AppError::Io {
                    path: repo_path.clone(),
                    source,
                })?;
                let channel_path = channel_entry.path();
                let channel_type = channel_entry.file_type().map_err(|source| AppError::Io {
                    path: channel_path.clone(),
                    source,
                })?;
                if !channel_type.is_dir() {
                    continue;
                }

                for revision_entry in
                    fs::read_dir(&channel_path).map_err(|source| AppError::Io {
                        path: channel_path.clone(),
                        source,
                    })?
                {
                    let revision_entry = revision_entry.map_err(|source| AppError::Io {
                        path: channel_path.clone(),
                        source,
                    })?;
                    let revision_path = revision_entry.path();
                    let revision_type =
                        revision_entry.file_type().map_err(|source| AppError::Io {
                            path: revision_path.clone(),
                            source,
                        })?;
                    if !revision_type.is_dir() {
                        continue;
                    }

                    let bytes = path_size(&revision_path)?;
                    if active_snapshots.contains(&normalize_existing_path(&revision_path)) {
                        kept.push(CleanupEntryReport {
                            path: revision_path,
                            bytes,
                            reason: String::from("active snapshot"),
                        });
                        continue;
                    }

                    fs::remove_dir_all(&revision_path).map_err(|source| AppError::Io {
                        path: revision_path.clone(),
                        source,
                    })?;
                    cleanup_empty_parent_dirs(
                        revision_path.parent(),
                        &self.paths.repo_snapshots_dir,
                    )?;
                    removed.push(CleanupEntryReport {
                        path: revision_path,
                        bytes,
                        reason: String::from("stale snapshot"),
                    });
                }
            }
        }

        Ok(CleanupScopeReport {
            scope: String::from("repos"),
            bytes_reclaimed: removed.iter().map(|entry| entry.bytes).sum(),
            removed,
            kept,
        })
    }

    fn cleanup_published_revisions(&self) -> Result<CleanupScopeReport, AppError> {
        let mut removed = Vec::new();
        let mut kept = Vec::new();
        if !self.paths.published_repos_dir.exists() {
            return Ok(CleanupScopeReport {
                scope: String::from("published"),
                removed,
                kept,
                bytes_reclaimed: 0,
            });
        }

        for repo_entry in
            fs::read_dir(&self.paths.published_repos_dir).map_err(|source| AppError::Io {
                path: self.paths.published_repos_dir.clone(),
                source,
            })?
        {
            let repo_entry = repo_entry.map_err(|source| AppError::Io {
                path: self.paths.published_repos_dir.clone(),
                source,
            })?;
            let repo_path = repo_entry.path();
            let repo_type = repo_entry.file_type().map_err(|source| AppError::Io {
                path: repo_path.clone(),
                source,
            })?;
            if !repo_type.is_dir() {
                continue;
            }

            let repo_name = repo_entry.file_name().to_string_lossy().to_string();
            let publish_state = self.read_publish_state(&repo_name)?;
            let keep_previous_revisions = publish_state
                .as_ref()
                .map(|state| state.keep_revisions)
                .unwrap_or(0);
            let live_root = repo_path.join("live");
            let active_revision = if path_exists(&live_root) {
                Some(normalize_existing_path(&live_root))
            } else {
                None
            };
            let revisions_root = repo_path.join("revisions");
            if !revisions_root.exists() {
                continue;
            }

            for channel_entry in fs::read_dir(&revisions_root).map_err(|source| AppError::Io {
                path: revisions_root.clone(),
                source,
            })? {
                let channel_entry = channel_entry.map_err(|source| AppError::Io {
                    path: revisions_root.clone(),
                    source,
                })?;
                let channel_path = channel_entry.path();
                let channel_type = channel_entry.file_type().map_err(|source| AppError::Io {
                    path: channel_path.clone(),
                    source,
                })?;
                if !channel_type.is_dir() {
                    continue;
                }

                let mut revision_paths = fs::read_dir(&channel_path)
                    .map_err(|source| AppError::Io {
                        path: channel_path.clone(),
                        source,
                    })?
                    .map(|entry| {
                        entry.map_err(|source| AppError::Io {
                            path: channel_path.clone(),
                            source,
                        })
                    })
                    .collect::<Result<Vec<_>, AppError>>()?
                    .into_iter()
                    .filter_map(|entry| match entry.file_type() {
                        Ok(file_type) if file_type.is_dir() => Some(Ok(entry.path())),
                        Ok(_) => None,
                        Err(source) => Some(Err(AppError::Io {
                            path: entry.path(),
                            source,
                        })),
                    })
                    .collect::<Result<Vec<_>, AppError>>()?;
                revision_paths.sort_by(|left, right| right.file_name().cmp(&left.file_name()));

                let mut retained = revision_paths
                    .iter()
                    .take(1 + keep_previous_revisions)
                    .map(|path| normalize_existing_path(path))
                    .collect::<HashSet<_>>();
                if let Some(active) = &active_revision {
                    retained.insert(active.clone());
                }

                for revision_path in revision_paths {
                    let canonical = normalize_existing_path(&revision_path);
                    let bytes = path_size(&revision_path)?;
                    if retained.contains(&canonical) {
                        let reason = if active_revision
                            .as_ref()
                            .map(|active| active == &canonical)
                            .unwrap_or(false)
                        {
                            String::from("active live revision")
                        } else {
                            format!(
                                "within {} retained published revision(s)",
                                1 + keep_previous_revisions
                            )
                        };
                        kept.push(CleanupEntryReport {
                            path: revision_path,
                            bytes,
                            reason,
                        });
                    } else {
                        fs::remove_dir_all(&revision_path).map_err(|source| AppError::Io {
                            path: revision_path.clone(),
                            source,
                        })?;
                        removed.push(CleanupEntryReport {
                            path: revision_path,
                            bytes,
                            reason: format!(
                                "older than retained published revision window for repo {repo_name}"
                            ),
                        });
                    }
                }
            }
        }

        Ok(CleanupScopeReport {
            scope: String::from("published"),
            bytes_reclaimed: removed.iter().map(|entry| entry.bytes).sum(),
            removed,
            kept,
        })
    }

    fn active_unified_snapshot_roots(&self) -> Result<HashSet<PathBuf>, AppError> {
        let repos = self.load_repo_config()?.repo;
        let mut active = HashSet::new();
        for repo in repos {
            if !repo.enabled || !matches!(repo.kind, RepoKind::Unified) {
                continue;
            }
            if let Some(snapshot_root) =
                cached_unified_snapshot_root(&repo, &self.paths.repo_state_dir)?
            {
                active.insert(normalize_existing_path(&snapshot_root));
            }
        }
        Ok(active)
    }

    fn run_requested_bootstraps(
        &self,
        packages: &[PackageRecord],
        plan: &TransactionPlan,
        requested_names: &HashSet<String>,
        target_root: &Path,
    ) -> Result<(), AppError> {
        let mut seen = HashSet::new();
        for planned in &plan.packages {
            let package_name = &planned.package.package.name;
            if !requested_names.contains(package_name) || !seen.insert(package_name.clone()) {
                continue;
            }
            let Some(bootstrap) = &planned.package.bootstrap else {
                continue;
            };
            if target_root != Path::new("/") {
                return Err(AppError::UnsupportedBootstrapTargetRoot(
                    target_root.to_path_buf(),
                ));
            }
            let bootstrap_plan =
                self.plan_bootstrap(packages, &planned.package.package.name, bootstrap)?;
            self.run_bootstrap(&bootstrap_plan)?;
        }
        Ok(())
    }

    fn ensure_cached_package(
        &self,
        package: &PackageRecord,
        requested: bool,
    ) -> Result<(), AppError> {
        let recipe_hash = recipe_source_hash(package)?;
        if self.cached_package_matches_recipe(package, &recipe_hash)? {
            return Ok(());
        }

        let operation = if requested {
            "build-requested-cache"
        } else {
            "build-dependency-cache"
        };
        let reason = if requested { "requested" } else { "dependency" };
        let requested_json = serde_json::to_string_pretty(&json!({
            "operation": operation,
            "package": package.package.name,
            "version": package.package.evr.to_string(),
            "reason": reason,
        }))?;
        let actions = vec![TransactionActionRecord {
            action_kind: String::from(operation),
            package_name: package.package.name.clone(),
            version_text: package.package.evr.to_string(),
            reason: String::from(reason),
        }];
        let transaction_id = create_transaction(
            &self.paths.database_path,
            operation,
            &requested_json,
            &actions,
        )?;
        update_transaction_status(&self.paths.database_path, transaction_id, "building")?;
        let log_path = self.build_log_path(transaction_id, &package.package.name);

        let build_result = stage_package(
            package,
            &self.paths.distfiles_dir,
            &self.paths.build_dir,
            &self.paths.packages_dir,
            transaction_id,
            &log_path,
            &[],
        );

        match build_result {
            Ok(report) => {
                record_cache_package(
                    &self.paths.database_path,
                    &CachePackageRecord {
                        name: package.package.name.clone(),
                        epoch: package.package.evr.epoch,
                        version: package.package.evr.version.clone(),
                        release: package.package.evr.release.clone(),
                        arch: package
                            .package
                            .architectures
                            .first()
                            .cloned()
                            .unwrap_or_else(|| String::from("any")),
                        archive_path: report.package_archive_path.display().to_string(),
                        checksum: report.package_archive_sha256.clone(),
                        recipe_hash: Some(recipe_hash),
                        build_transaction_id: transaction_id,
                    },
                )?;
                let repo_index = generate_binary_repo_index(&self.paths.packages_dir, None)?;
                let transaction_path = self
                    .paths
                    .transactions_dir
                    .join(format!("{transaction_id}.json"));
                let transaction_json = serde_json::to_vec_pretty(&json!({
                    "transaction_id": transaction_id,
                    "operation": operation,
                    "package": {
                        "name": package.package.name,
                        "version": package.package.evr.to_string(),
                    },
                    "repo_index": &repo_index,
                    "build_report": &report,
                }))?;
                fs::write(&transaction_path, transaction_json).map_err(|source| AppError::Io {
                    path: transaction_path,
                    source,
                })?;
                update_transaction_status(&self.paths.database_path, transaction_id, "packaged")?;
                Ok(())
            }
            Err(err) => {
                let transaction_path = self
                    .paths
                    .transactions_dir
                    .join(format!("{transaction_id}.json"));
                let transaction_json = serde_json::to_vec_pretty(&json!({
                    "transaction_id": transaction_id,
                    "operation": operation,
                    "package": {
                        "name": package.package.name,
                        "version": package.package.evr.to_string(),
                    },
                    "status": "failed",
                    "log_path": log_path,
                    "error": err.to_string(),
                }))?;
                fs::write(&transaction_path, transaction_json).map_err(|source| AppError::Io {
                    path: transaction_path,
                    source,
                })?;
                let _ =
                    update_transaction_status(&self.paths.database_path, transaction_id, "failed");
                Err(AppError::from(err))
            }
        }
    }

    fn cached_package_matches_recipe(
        &self,
        package: &PackageRecord,
        recipe_hash: &str,
    ) -> Result<bool, AppError> {
        let arch = package
            .package
            .architectures
            .first()
            .cloned()
            .unwrap_or_else(|| String::from("any"));
        let records = find_cache_packages(
            &self.paths.database_path,
            &package.package.name,
            package.package.evr.epoch,
            &package.package.evr.version,
            &package.package.evr.release,
            &arch,
        )?;
        Ok(records.into_iter().any(|record| {
            record.recipe_hash.as_deref() == Some(recipe_hash)
                && Path::new(&record.archive_path).exists()
        }))
    }

    fn bootstrap_cached_package_ready(&self, package: &PackageRecord) -> Result<bool, AppError> {
        let recipe_hash = recipe_source_hash(package)?;
        if self.cached_package_matches_recipe(package, &recipe_hash)? {
            return Ok(true);
        }

        let arch = package
            .package
            .architectures
            .first()
            .cloned()
            .unwrap_or_else(|| String::from("any"));
        let records = find_cache_packages(
            &self.paths.database_path,
            &package.package.name,
            package.package.evr.epoch,
            &package.package.evr.version,
            &package.package.evr.release,
            &arch,
        )?;
        let Some(legacy_record) = records.into_iter().find(|record| {
            record.recipe_hash.is_none() && Path::new(&record.archive_path).exists()
        }) else {
            return Ok(false);
        };

        let exact_constraint = Constraint::parse(&format!("= {}", package.package.evr))?;
        let cached = match find_cached_binary_package(
            &self.paths.packages_dir,
            &package.package.name,
            &exact_constraint,
        ) {
            Ok(cached) => cached,
            Err(_) => return Ok(false),
        };

        record_cache_package(
            &self.paths.database_path,
            &CachePackageRecord {
                name: package.package.name.clone(),
                epoch: package.package.evr.epoch,
                version: package.package.evr.version.clone(),
                release: package.package.evr.release.clone(),
                arch,
                archive_path: cached.archive_path.display().to_string(),
                checksum: cached.archive_sha256,
                recipe_hash: Some(recipe_hash),
                build_transaction_id: legacy_record.build_transaction_id,
            },
        )?;
        Ok(true)
    }

    fn build_bootstrap_package(
        &self,
        package: &PackageRecord,
        stage_name: &str,
        extra_env: &[(String, String)],
    ) -> Result<BuildReport, AppError> {
        let requested_json = serde_json::to_string_pretty(&json!({
            "operation": "bootstrap-build",
            "stage": stage_name,
            "package": package.package.name,
            "version": package.package.evr.to_string(),
        }))?;
        let actions = vec![TransactionActionRecord {
            action_kind: String::from("bootstrap-build"),
            package_name: package.package.name.clone(),
            version_text: package.package.evr.to_string(),
            reason: stage_name.to_owned(),
        }];
        let transaction_id = create_transaction(
            &self.paths.database_path,
            "bootstrap-build",
            &requested_json,
            &actions,
        )?;
        update_transaction_status(&self.paths.database_path, transaction_id, "building")?;
        let log_path = self.build_log_path(transaction_id, &package.package.name);

        let build_result = stage_package(
            package,
            &self.paths.distfiles_dir,
            &self.paths.build_dir,
            &self.paths.packages_dir,
            transaction_id,
            &log_path,
            extra_env,
        );

        match build_result {
            Ok(report) => {
                let recipe_hash = recipe_source_hash(package)?;
                record_cache_package(
                    &self.paths.database_path,
                    &CachePackageRecord {
                        name: package.package.name.clone(),
                        epoch: package.package.evr.epoch,
                        version: package.package.evr.version.clone(),
                        release: package.package.evr.release.clone(),
                        arch: package
                            .package
                            .architectures
                            .first()
                            .cloned()
                            .unwrap_or_else(|| String::from("any")),
                        archive_path: report.package_archive_path.display().to_string(),
                        checksum: report.package_archive_sha256.clone(),
                        recipe_hash: Some(recipe_hash),
                        build_transaction_id: transaction_id,
                    },
                )?;
                let repo_index = generate_binary_repo_index(&self.paths.packages_dir, None)?;
                let transaction_path = self
                    .paths
                    .transactions_dir
                    .join(format!("{transaction_id}.json"));
                let transaction_json = serde_json::to_vec_pretty(&json!({
                    "transaction_id": transaction_id,
                    "operation": "bootstrap-build",
                    "stage": stage_name,
                    "package": {
                        "name": package.package.name,
                        "version": package.package.evr.to_string(),
                    },
                    "extra_env": extra_env,
                    "repo_index": &repo_index,
                    "build_report": &report,
                }))?;
                fs::write(&transaction_path, transaction_json).map_err(|source| AppError::Io {
                    path: transaction_path,
                    source,
                })?;
                update_transaction_status(&self.paths.database_path, transaction_id, "packaged")?;
                Ok(report)
            }
            Err(err) => {
                let transaction_path = self
                    .paths
                    .transactions_dir
                    .join(format!("{transaction_id}.json"));
                let transaction_json = serde_json::to_vec_pretty(&json!({
                    "transaction_id": transaction_id,
                    "operation": "bootstrap-build",
                    "stage": stage_name,
                    "package": {
                        "name": package.package.name,
                        "version": package.package.evr.to_string(),
                    },
                    "status": "failed",
                    "extra_env": extra_env,
                    "log_path": log_path,
                    "error": err.to_string(),
                }))?;
                fs::write(&transaction_path, transaction_json).map_err(|source| AppError::Io {
                    path: transaction_path,
                    source,
                })?;
                let _ =
                    update_transaction_status(&self.paths.database_path, transaction_id, "failed");
                Err(AppError::from(err))
            }
        }
    }

    fn prepare_install_operations(
        &self,
        plan: &TransactionPlan,
        requested_names: &HashSet<String>,
        installed: &HashMap<String, InstalledPackageRecord>,
    ) -> Result<Vec<PreparedInstall>, AppError> {
        let mut prepared = Vec::new();
        for planned in &plan.packages {
            let name = planned.package.package.name.clone();
            let requested = requested_names.contains(&name);
            let existing = installed.get(&name);
            let same_version = existing
                .map(|existing| {
                    same_version(
                        existing,
                        planned.package.package.evr.epoch,
                        &planned.package.package.evr.version,
                        &planned.package.package.evr.release,
                    )
                })
                .unwrap_or(false);
            if same_version && !requested {
                continue;
            }

            let exact_constraint =
                Constraint::parse(&format!("= {}", planned.package.package.evr))?;
            self.ensure_cached_package(&planned.package, requested)?;
            let cached =
                find_cached_binary_package(&self.paths.packages_dir, &name, &exact_constraint)?;
            let manifest = installable_manifest(&cached.manifest, &cached.info.owned_prefixes)?;
            let action = if existing.is_some() {
                if same_version {
                    String::from("reinstall")
                } else {
                    String::from("upgrade")
                }
            } else if requested {
                String::from("install")
            } else {
                String::from("install-dependency")
            };
            let install_reason = if requested
                || existing
                    .map(|existing| existing.install_reason == "explicit")
                    .unwrap_or(false)
            {
                String::from("explicit")
            } else {
                String::from("auto")
            };
            prepared.push(PreparedInstall {
                package_name: name,
                version: planned.package.package.evr.to_string(),
                install_reason,
                action,
                cached,
                manifest,
            });
        }

        preflight_planned_paths(&prepared)?;
        Ok(prepared)
    }

    fn preflight_installed_conflicts(
        &self,
        installs: &[PreparedInstall],
        excluded_owners: &[String],
    ) -> Result<(), AppError> {
        for install in installs {
            let install_paths = install
                .manifest
                .entries
                .iter()
                .filter(|entry| entry.file_type != "dir")
                .map(|entry| entry.path.clone())
                .collect::<Vec<_>>();
            let conflicts = find_installed_file_conflicts_excluding(
                &self.paths.database_path,
                &install.package_name,
                &install_paths,
                excluded_owners,
            )?;
            if let Some(conflict) = conflicts.into_iter().next() {
                return Err(AppError::InstalledFileConflict {
                    path: conflict.path,
                    owner: conflict.owner,
                });
            }
        }
        Ok(())
    }

    fn execute_transaction(
        &self,
        operation: &str,
        requested_packages: Vec<String>,
        target_root: &Path,
        installs: &[PreparedInstall],
        removals: &[PreparedRemoval],
        requested_json_value: serde_json::Value,
    ) -> Result<TransactionReport, AppError> {
        let excluded_owners = removals
            .iter()
            .map(|package| package.package.name.clone())
            .collect::<Vec<_>>();
        self.preflight_installed_conflicts(installs, &excluded_owners)?;

        let mut actions = removals
            .iter()
            .map(|package| TransactionActionRecord {
                action_kind: package.action.clone(),
                package_name: package.package.name.clone(),
                version_text: format_evr_parts(
                    package.package.epoch,
                    &package.package.version,
                    &package.package.release,
                ),
                reason: package.package.install_reason.clone(),
            })
            .collect::<Vec<_>>();
        actions.extend(installs.iter().map(|package| TransactionActionRecord {
            action_kind: package.action.clone(),
            package_name: package.package_name.clone(),
            version_text: package.version.clone(),
            reason: package.install_reason.clone(),
        }));

        let requested_json = serde_json::to_string_pretty(&requested_json_value)?;
        let transaction_id = create_transaction(
            &self.paths.database_path,
            operation,
            &requested_json,
            &actions,
        )?;
        update_transaction_status(&self.paths.database_path, transaction_id, "committing")?;

        let transaction_result = (|| -> Result<TransactionReport, AppError> {
            let mut package_reports = Vec::new();

            for removal in removals {
                let removed_entries = remove_package_from_root(
                    &self.paths.database_path,
                    &removal.package,
                    target_root,
                )?;
                remove_installed_package_records(&self.paths.database_path, &removal.package.name)?;
                package_reports.push(TransactionPackageReport {
                    package_name: removal.package.name.clone(),
                    version: format_evr_parts(
                        removal.package.epoch,
                        &removal.package.version,
                        &removal.package.release,
                    ),
                    action: removal.action.clone(),
                    install_reason: Some(removal.package.install_reason.clone()),
                    archive_path: None,
                    archive_sha256: removal.package.archive_checksum.clone(),
                    entries: removed_entries,
                });
            }

            for install in installs {
                let stage_dir = self.paths.build_dir.join(format!(
                    "install-{}-tx{}",
                    sanitize(&install.package_name),
                    transaction_id
                ));
                if stage_dir.exists() {
                    fs::remove_dir_all(&stage_dir).map_err(|source| AppError::Io {
                        path: stage_dir.clone(),
                        source,
                    })?;
                }

                let result = install_package_into_root(
                    &self.paths.database_path,
                    install,
                    target_root,
                    &stage_dir,
                );
                let _ = fs::remove_dir_all(&stage_dir);
                package_reports.push(result?);
            }

            let report = TransactionReport {
                transaction_id,
                operation: operation.to_owned(),
                requested_packages: requested_packages.clone(),
                target_root: target_root.to_path_buf(),
                packages: package_reports,
            };
            Ok(report)
        })();

        match transaction_result {
            Ok(report) => {
                self.write_transaction_report_record(
                    operation,
                    &requested_json_value,
                    &report,
                    "applied",
                    "pending",
                    None,
                )?;
                update_transaction_status(&self.paths.database_path, transaction_id, "applied")?;
                Ok(report)
            }
            Err(err) => {
                let _ = self.write_transaction_error_record(
                    transaction_id,
                    operation,
                    &requested_json_value,
                    "failed",
                    "commit",
                    &err.to_string(),
                );
                let _ =
                    update_transaction_status(&self.paths.database_path, transaction_id, "failed");
                Err(err)
            }
        }
    }

    fn finalize_transaction(
        &self,
        report: TransactionReport,
        target_root: &Path,
        options: TransactionOptions,
    ) -> Result<TransactionReport, AppError> {
        update_transaction_status(
            &self.paths.database_path,
            report.transaction_id,
            "maintaining",
        )?;
        self.update_transaction_report_record(
            report.transaction_id,
            "maintaining",
            "running",
            None,
        )?;

        match self.run_post_success_maintenance(target_root, options) {
            Ok(()) => {
                self.update_transaction_report_record(
                    report.transaction_id,
                    "complete",
                    "complete",
                    None,
                )?;
                update_transaction_status(
                    &self.paths.database_path,
                    report.transaction_id,
                    "complete",
                )?;
                Ok(report)
            }
            Err(err) => {
                let reason = err.to_string();
                let transaction_path = self.transaction_record_path(report.transaction_id);
                let _ = self.update_transaction_report_record(
                    report.transaction_id,
                    "maintenance-failed",
                    "failed",
                    Some(&reason),
                );
                let _ = update_transaction_status(
                    &self.paths.database_path,
                    report.transaction_id,
                    "maintenance-failed",
                );
                Err(AppError::PostTransactionMaintenanceFailed {
                    transaction_id: report.transaction_id,
                    transaction_path,
                    reason,
                })
            }
        }
    }

    fn load_packages(&self, recipe_root: Option<&Path>) -> Result<Vec<PackageRecord>, AppError> {
        Ok(self
            .load_snapshots(recipe_root, SnapshotLoadMode::Strict)?
            .into_iter()
            .flat_map(|snapshot| snapshot.packages)
            .collect())
    }

    fn load_snapshots(
        &self,
        recipe_root: Option<&Path>,
        mode: SnapshotLoadMode,
    ) -> Result<Vec<RepoSnapshot>, AppError> {
        let configured = if let Some(path) = recipe_root {
            vec![local_recipe_repo(path)]
        } else {
            self.load_repo_config()?.repo
        };

        configured
            .into_iter()
            .filter(|repo| repo.enabled)
            .filter(|repo| !matches!(repo.kind, RepoKind::Binary))
            .filter_map(|repo| match repo.kind {
                RepoKind::Recipe => Some(
                    load_recipe_repo(Path::new(&repo.url), repo.priority).map_err(AppError::from),
                ),
                RepoKind::Unified => {
                    match cached_unified_snapshot_root(&repo, &self.paths.repo_state_dir) {
                        Ok(Some(snapshot_root)) => Some(
                            load_recipe_repo(&snapshot_root, repo.priority).map_err(AppError::from),
                        ),
                        Ok(None) => match mode {
                            SnapshotLoadMode::Strict => {
                                Some(Err(AppError::UnifiedRepoNotUpdated { repo: repo.name }))
                            }
                            SnapshotLoadMode::BestEffort => None,
                        },
                        Err(err) => Some(Err(AppError::from(err))),
                    }
                }
                RepoKind::Binary => None,
            })
            .collect()
    }

    fn load_repo_config(&self) -> Result<RepoConfigFile, AppError> {
        if !self.paths.repo_config_path.exists() {
            return Ok(RepoConfigFile::default());
        }

        let contents =
            fs::read_to_string(&self.paths.repo_config_path).map_err(|source| AppError::Io {
                path: self.paths.repo_config_path.clone(),
                source,
            })?;
        toml::from_str(&contents).map_err(|source| AppError::RepoConfigParse {
            path: self.paths.repo_config_path.clone(),
            source,
        })
    }

    fn save_repo_config(&self, config: &RepoConfigFile) -> Result<(), AppError> {
        if let Some(parent) = self.paths.repo_config_path.parent() {
            fs::create_dir_all(parent).map_err(|source| AppError::Io {
                path: parent.to_path_buf(),
                source,
            })?;
        }
        let contents = toml::to_string_pretty(config)?;
        fs::write(&self.paths.repo_config_path, contents).map_err(|source| AppError::Io {
            path: self.paths.repo_config_path.clone(),
            source,
        })?;
        Ok(())
    }

    fn update_transaction_report_record(
        &self,
        transaction_id: i64,
        status: &str,
        maintenance_status: &str,
        maintenance_error: Option<&str>,
    ) -> Result<(), AppError> {
        let transaction_path = self.transaction_record_path(transaction_id);
        let contents = fs::read_to_string(&transaction_path).map_err(|source| AppError::Io {
            path: transaction_path.clone(),
            source,
        })?;
        let mut record = serde_json::from_str::<serde_json::Value>(&contents)?;
        record["status"] = json!(status);
        record["maintenance"] = json!({
            "status": maintenance_status,
        });
        if let Some(error) = maintenance_error {
            record["maintenance"]["error"] = json!(error);
        }
        let transaction_json = serde_json::to_vec_pretty(&record)?;
        fs::write(&transaction_path, transaction_json).map_err(|source| AppError::Io {
            path: transaction_path,
            source,
        })?;
        Ok(())
    }

    fn published_repo_root(&self, repo_name: &str) -> PathBuf {
        self.paths.published_repos_dir.join(sanitize(repo_name))
    }

    fn publish_state_path(&self, repo_name: &str) -> PathBuf {
        self.published_repo_root(repo_name).join("publish.toml")
    }

    fn write_publish_state(&self, repo_name: &str, state: &PublishState) -> Result<(), AppError> {
        let path = self.publish_state_path(repo_name);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|source| AppError::Io {
                path: parent.to_path_buf(),
                source,
            })?;
        }
        let contents = toml::to_string_pretty(state)?;
        fs::write(&path, contents).map_err(|source| AppError::Io {
            path: path.clone(),
            source,
        })?;
        Ok(())
    }

    fn transaction_record_path(&self, transaction_id: i64) -> PathBuf {
        self.paths
            .transactions_dir
            .join(format!("{transaction_id}.json"))
    }

    fn write_transaction_report_record(
        &self,
        operation: &str,
        requested_json_value: &serde_json::Value,
        report: &TransactionReport,
        status: &str,
        maintenance_status: &str,
        maintenance_error: Option<&str>,
    ) -> Result<(), AppError> {
        let mut maintenance = json!({
            "status": maintenance_status,
        });
        if let Some(error) = maintenance_error {
            maintenance["error"] = json!(error);
        }
        let transaction_path = self.transaction_record_path(report.transaction_id);
        let transaction_json = serde_json::to_vec_pretty(&json!({
            "transaction_id": report.transaction_id,
            "operation": operation,
            "requested": requested_json_value,
            "status": status,
            "maintenance": maintenance,
            "report": report,
        }))?;
        fs::write(&transaction_path, transaction_json).map_err(|source| AppError::Io {
            path: transaction_path,
            source,
        })?;
        Ok(())
    }

    fn write_transaction_error_record(
        &self,
        transaction_id: i64,
        operation: &str,
        requested_json_value: &serde_json::Value,
        status: &str,
        phase: &str,
        error: &str,
    ) -> Result<(), AppError> {
        let transaction_path = self.transaction_record_path(transaction_id);
        let transaction_json = serde_json::to_vec_pretty(&json!({
            "transaction_id": transaction_id,
            "operation": operation,
            "requested": requested_json_value,
            "status": status,
            "phase": phase,
            "error": error,
        }))?;
        fs::write(&transaction_path, transaction_json).map_err(|source| AppError::Io {
            path: transaction_path,
            source,
        })?;
        Ok(())
    }

    fn read_publish_state(&self, repo_name: &str) -> Result<Option<PublishState>, AppError> {
        let path = self.publish_state_path(repo_name);
        if !path.exists() {
            return Ok(None);
        }
        let contents = fs::read_to_string(&path).map_err(|source| AppError::Io {
            path: path.clone(),
            source,
        })?;
        toml::from_str(&contents)
            .map(Some)
            .map_err(|source| AppError::PublishStateParse { path, source })
    }

    fn list_publish_states(&self) -> Result<Vec<PublishState>, AppError> {
        if !self.paths.published_repos_dir.exists() {
            return Ok(Vec::new());
        }
        let mut states = Vec::new();
        for entry in
            fs::read_dir(&self.paths.published_repos_dir).map_err(|source| AppError::Io {
                path: self.paths.published_repos_dir.clone(),
                source,
            })?
        {
            let entry = entry.map_err(|source| AppError::Io {
                path: self.paths.published_repos_dir.clone(),
                source,
            })?;
            let file_type = entry.file_type().map_err(|source| AppError::Io {
                path: entry.path(),
                source,
            })?;
            if !file_type.is_dir() {
                continue;
            }
            let repo_name = entry.file_name().to_string_lossy().to_string();
            if let Some(state) = self.read_publish_state(&repo_name)? {
                if state.remember {
                    states.push(state);
                }
            }
        }
        Ok(states)
    }

    fn run_post_success_maintenance(
        &self,
        target_root: &Path,
        options: TransactionOptions,
    ) -> Result<(), AppError> {
        self.refresh_root_runtime_state(target_root)?;
        if options.skip_publish_maintenance {
            return Ok(());
        }
        let publish_states = self.list_publish_states()?;
        if publish_states.is_empty() {
            return Ok(());
        }

        for publish_state in publish_states {
            self.publish_repo_with_options(
                Some(Path::new(&publish_state.source_root)),
                Some(&publish_state.repo_name),
                &publish_state.channel,
                None,
                publish_state.keep_revisions,
                RepoPublishOptions {
                    remember_publish_state: publish_state.remember,
                },
            )?;
        }
        self.cleanup(CleanupTarget::All)?;
        Ok(())
    }

    fn refresh_root_runtime_state(&self, target_root: &Path) -> Result<(), AppError> {
        if target_root != Path::new("/") {
            return Ok(());
        }

        self.run_root_runtime_maintenance(Path::new("/"))
    }

    fn run_root_runtime_maintenance(&self, target_root: &Path) -> Result<(), AppError> {
        for relative_script in ROOT_RUNTIME_MAINTENANCE_SCRIPTS {
            let script = target_root.join(relative_script);
            if !script.exists() {
                continue;
            }

            let status = Command::new(&script)
                .status()
                .map_err(|source| AppError::Io {
                    path: script.clone(),
                    source,
                })?;
            if !status.success() {
                return Err(AppError::MaintenanceCommandFailed {
                    command: script.display().to_string(),
                    status: status
                        .code()
                        .map(|code| format!("exit code {code}"))
                        .unwrap_or_else(|| String::from("signal")),
                });
            }
        }
        Ok(())
    }

    fn update_unified_repo(
        &self,
        repo: &RepoConfigEntry,
    ) -> Result<UnifiedRepoSyncReport, AppError> {
        sync_unified_repo(
            repo,
            &self.paths.repo_state_dir,
            &self.paths.repo_snapshots_dir,
        )
        .map_err(AppError::from)
    }
}

fn local_recipe_repo(path: &Path) -> RepoConfigEntry {
    RepoConfigEntry {
        name: String::from("workspace"),
        kind: RepoKind::Recipe,
        url: path.to_string_lossy().into_owned(),
        channel: None,
        priority: 50,
        enabled: true,
        trust_policy: RepoTrustMode::Local,
        sync_strategy: RepoSyncStrategy::File,
    }
}

const fn format_cleanup_target(target: CleanupTarget) -> &'static str {
    match target {
        CleanupTarget::Builds => "builds",
        CleanupTarget::Repos => "repos",
        CleanupTarget::Published => "published",
        CleanupTarget::All => "all",
    }
}

fn map_unified_update_report(name: &str, report: UnifiedRepoSyncReport) -> UpdateRepoReport {
    UpdateRepoReport {
        name: name.to_owned(),
        kind: String::from("unified"),
        action: if report.changed {
            String::from("updated")
        } else {
            String::from("unchanged")
        },
        channel: Some(report.channel),
        revision: Some(report.revision),
        snapshot_root: Some(report.snapshot_root),
        package_count: report.package_count,
        file_count: report.file_count,
    }
}

fn map_repo_export_report(report: UnifiedRepoExportReport) -> RepoExportReport {
    RepoExportReport {
        repo_name: report.repo_name,
        channel: report.channel,
        revision: report.revision,
        output_root: report.output_root,
        package_count: report.package_count,
        version_count: report.version_count,
        file_count: report.file_count,
    }
}

const fn publish_state_remember_default() -> bool {
    true
}

const fn format_repo_trust_mode(mode: RepoTrustMode) -> &'static str {
    match mode {
        RepoTrustMode::Local => "local",
        RepoTrustMode::DigestPinned => "digest-pinned",
    }
}

const fn format_repo_sync_strategy(strategy: RepoSyncStrategy) -> &'static str {
    match strategy {
        RepoSyncStrategy::File => "file",
        RepoSyncStrategy::StaticHttp => "static-http",
    }
}

impl BootstrapProgress {
    fn from_plan(plan: &BootstrapPlan) -> Self {
        Self {
            total_stages: plan.stages.len(),
            total_packages: plan.stages.iter().map(|stage| stage.packages.len()).sum(),
            completed_stages: 0,
            completed_packages: 0,
        }
    }
}

fn format_bootstrap_progress(progress: &BootstrapProgress, message: &str) -> String {
    format!(
        "{} stages {}/{} | packages {}/{} | {}",
        render_progress_bar(progress.completed_packages, progress.total_packages, 20),
        progress.completed_stages,
        progress.total_stages,
        progress.completed_packages,
        progress.total_packages,
        message
    )
}

fn render_progress_bar(completed: usize, total: usize, width: usize) -> String {
    if total == 0 {
        return format!("[{}]", "-".repeat(width));
    }

    let filled = completed.saturating_mul(width) / total;
    let mut bar = String::with_capacity(width + 2);
    bar.push('[');
    for index in 0..width {
        if index < filled {
            bar.push('=');
        } else if index == filled && completed < total {
            bar.push('>');
        } else {
            bar.push('-');
        }
    }
    bar.push(']');
    bar
}

fn format_byte_count(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KiB", "MiB", "GiB", "TiB"];
    let mut value = bytes as f64;
    let mut unit = 0usize;
    while value >= 1024.0 && unit + 1 < UNITS.len() {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} {}", UNITS[unit])
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}

fn transaction_status_allows_cleanup(status: &str) -> bool {
    !matches!(
        status,
        "planned" | "building" | "committing" | "applied" | "maintaining"
    )
}

fn transaction_id_from_work_dir_name(name: &str) -> Option<i64> {
    let (_, suffix) = name.rsplit_once("-tx")?;
    if suffix.is_empty() || !suffix.chars().all(|ch| ch.is_ascii_digit()) {
        return None;
    }
    suffix.parse().ok()
}

fn sanitize_log_name(name: &str) -> String {
    name.chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
                ch
            } else {
                '-'
            }
        })
        .collect()
}

fn path_size(path: &Path) -> Result<u64, AppError> {
    let metadata = fs::symlink_metadata(path).map_err(|source| AppError::Io {
        path: path.to_path_buf(),
        source,
    })?;
    if metadata.is_file() || metadata.file_type().is_symlink() {
        return Ok(metadata.len());
    }
    if metadata.is_dir() {
        let mut size = 0u64;
        for entry in fs::read_dir(path).map_err(|source| AppError::Io {
            path: path.to_path_buf(),
            source,
        })? {
            let entry = entry.map_err(|source| AppError::Io {
                path: path.to_path_buf(),
                source,
            })?;
            size += path_size(&entry.path())?;
        }
        return Ok(size);
    }
    Ok(0)
}

fn normalize_existing_path(path: &Path) -> PathBuf {
    fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

fn recipe_source_hash(package: &PackageRecord) -> Result<String, AppError> {
    let recipe_dir = package
        .recipe_path
        .parent()
        .ok_or_else(|| AppError::InvalidRecipePath(package.recipe_path.clone()))?;
    let mut hasher = Sha256::new();
    hash_recipe_path(recipe_dir, recipe_dir, &mut hasher)?;
    Ok(format!("{:x}", hasher.finalize()))
}

fn hash_recipe_path(path: &Path, root: &Path, hasher: &mut Sha256) -> Result<(), AppError> {
    let metadata = fs::symlink_metadata(path).map_err(|source| AppError::Io {
        path: path.to_path_buf(),
        source,
    })?;
    let relative = path.strip_prefix(root).unwrap_or(path);
    hasher.update(relative.to_string_lossy().as_bytes());

    if metadata.file_type().is_symlink() {
        hasher.update(b"symlink");
        let target = fs::read_link(path).map_err(|source| AppError::Io {
            path: path.to_path_buf(),
            source,
        })?;
        hasher.update(target.to_string_lossy().as_bytes());
        return Ok(());
    }

    if metadata.is_file() {
        hasher.update(b"file");
        hasher.update(fs::read(path).map_err(|source| AppError::Io {
            path: path.to_path_buf(),
            source,
        })?);
        return Ok(());
    }

    if metadata.is_dir() {
        hasher.update(b"dir");
        let mut children = fs::read_dir(path)
            .map_err(|source| AppError::Io {
                path: path.to_path_buf(),
                source,
            })?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|source| AppError::Io {
                path: path.to_path_buf(),
                source,
            })?;
        children.sort_by_key(|entry| entry.file_name());
        for child in children {
            hash_recipe_path(&child.path(), root, hasher)?;
        }
    }

    Ok(())
}

fn topo_sort_stage_names(
    bootstrap_package_name: &str,
    stages: &[BootstrapStage],
) -> Result<Vec<String>, AppError> {
    let mut stage_by_name = HashMap::new();
    for stage in stages {
        stage_by_name.insert(stage.name.clone(), stage);
    }

    let mut ordered = Vec::new();
    let mut temporary = HashSet::new();
    let mut permanent = HashSet::new();

    for stage in stages {
        visit_stage(
            bootstrap_package_name,
            stage,
            &stage_by_name,
            &mut temporary,
            &mut permanent,
            &mut ordered,
        )?;
    }

    Ok(ordered)
}

fn visit_stage(
    bootstrap_package_name: &str,
    stage: &BootstrapStage,
    stage_by_name: &HashMap<String, &BootstrapStage>,
    temporary: &mut HashSet<String>,
    permanent: &mut HashSet<String>,
    ordered: &mut Vec<String>,
) -> Result<(), AppError> {
    if permanent.contains(&stage.name) {
        return Ok(());
    }
    if !temporary.insert(stage.name.clone()) {
        return Err(AppError::BootstrapCycle {
            package: bootstrap_package_name.to_owned(),
        });
    }

    for dependency_name in &stage.depends_on {
        let dependency = stage_by_name
            .get(dependency_name)
            .expect("validated bootstrap dependency exists");
        visit_stage(
            bootstrap_package_name,
            dependency,
            stage_by_name,
            temporary,
            permanent,
            ordered,
        )?;
    }

    temporary.remove(&stage.name);
    permanent.insert(stage.name.clone());
    ordered.push(stage.name.clone());
    Ok(())
}

fn resolve_bootstrap_stage_packages(
    packages: &[PackageRecord],
    bootstrap_package_name: &str,
    stage: &BootstrapStage,
) -> Result<Vec<PackageRecord>, AppError> {
    let requests = stage
        .packages
        .iter()
        .map(|package_name| {
            Ok(RequestedPackage {
                name: package_name.clone(),
                constraint: Constraint::parse("*")?,
            })
        })
        .collect::<Result<Vec<_>, AppError>>()?;
    let plan = solve(
        packages,
        &requests,
        &SolveOptions {
            include_build_dependencies: true,
            include_optional_dependencies: false,
        },
    )?;
    let requested_names = stage.packages.iter().cloned().collect::<HashSet<_>>();
    let selected = plan
        .packages
        .into_iter()
        .filter(|planned| requested_names.contains(&planned.package.package.name))
        .map(|planned| planned.package)
        .collect::<Vec<_>>();

    let resolved_names = selected
        .iter()
        .map(|package| package.package.name.clone())
        .collect::<HashSet<_>>();
    for package_name in &stage.packages {
        if !resolved_names.contains(package_name) {
            return Err(AppError::UnknownBootstrapPackage {
                package: bootstrap_package_name.to_owned(),
                stage_package: package_name.clone(),
            });
        }
    }

    Ok(selected)
}

fn read_manifest(path: &Path) -> Result<PackageManifest, AppError> {
    let contents = fs::read(path).map_err(|source| AppError::Io {
        path: path.to_path_buf(),
        source,
    })?;
    Ok(serde_json::from_slice(&contents)?)
}

fn preflight_stage_manifest_paths(
    manifest: &PackageManifest,
    package_name: &str,
    seen_paths: &mut BTreeMap<String, String>,
) -> Result<(), AppError> {
    for entry in manifest
        .entries
        .iter()
        .filter(|entry| entry.file_type != "dir")
    {
        if let Some(owner) = seen_paths.insert(entry.path.clone(), package_name.to_owned()) {
            if owner != package_name {
                return Err(AppError::PlannedFileConflict {
                    path: entry.path.clone(),
                    owner,
                    incoming: package_name.to_owned(),
                });
            }
        }
    }
    Ok(())
}

fn installable_manifest(
    manifest: &PackageManifest,
    owned_prefixes: &[String],
) -> Result<PackageManifest, AppError> {
    let normalized_prefixes = if owned_prefixes.is_empty() {
        vec![String::from("/usr/local")]
    } else {
        owned_prefixes
            .iter()
            .map(|prefix| normalize_prefix(prefix))
            .collect::<Vec<_>>()
    };
    let mut entries = Vec::new();
    for entry in &manifest.entries {
        if entry.file_type == "dir" {
            entries.push(entry.clone());
            continue;
        }
        if normalized_prefixes
            .iter()
            .any(|prefix| path_within_prefix(&entry.path, prefix))
        {
            entries.push(entry.clone());
            continue;
        }
        return Err(AppError::UnmanagedPath(entry.path.clone()));
    }
    Ok(PackageManifest {
        package_name: manifest.package_name.clone(),
        version: manifest.version.clone(),
        entries,
    })
}

fn installed_package_map(
    packages: Vec<InstalledPackageRecord>,
) -> HashMap<String, InstalledPackageRecord> {
    packages
        .into_iter()
        .map(|package| (package.name.clone(), package))
        .collect()
}

fn same_version(
    package: &InstalledPackageRecord,
    epoch: u64,
    version: &str,
    release: &str,
) -> bool {
    package.epoch == epoch && package.version == version && package.release == release
}

fn preflight_planned_paths(installs: &[PreparedInstall]) -> Result<(), AppError> {
    let mut owners = BTreeMap::new();
    for install in installs {
        for entry in install
            .manifest
            .entries
            .iter()
            .filter(|entry| entry.file_type != "dir")
        {
            if let Some(owner) = owners.insert(entry.path.clone(), install.package_name.clone()) {
                if owner != install.package_name {
                    return Err(AppError::PlannedFileConflict {
                        path: entry.path.clone(),
                        owner,
                        incoming: install.package_name.clone(),
                    });
                }
            }
        }
    }
    Ok(())
}

fn install_package_into_root(
    database_path: &Path,
    install: &PreparedInstall,
    target_root: &Path,
    stage_dir: &Path,
) -> Result<TransactionPackageReport, AppError> {
    extract_binary_package(&install.cached.archive_path, stage_dir)?;
    let extracted_root = stage_dir.join("root");
    if !extracted_root.exists() {
        return Err(AppError::MissingExtractedRoot(extracted_root));
    }

    let old_paths = list_installed_files_for_package(database_path, &install.package_name)?;
    let new_paths = install
        .manifest
        .entries
        .iter()
        .filter(|entry| entry.file_type != "dir")
        .map(|entry| entry.path.clone())
        .collect::<HashSet<_>>();
    let stale_paths = old_paths
        .into_iter()
        .filter(|path| !new_paths.contains(path))
        .collect::<Vec<_>>();
    remove_paths_from_root(&stale_paths, target_root)?;

    copy_tree_into(&extracted_root, target_root)?;
    record_installed_package(
        database_path,
        &install.cached.info,
        &install.manifest,
        &install.cached.archive_sha256,
        Some("local-cache"),
        &install.install_reason,
    )?;

    Ok(TransactionPackageReport {
        package_name: install.package_name.clone(),
        version: install.version.clone(),
        action: install.action.clone(),
        install_reason: Some(install.install_reason.clone()),
        archive_path: Some(install.cached.archive_path.clone()),
        archive_sha256: Some(install.cached.archive_sha256.clone()),
        entries: install
            .manifest
            .entries
            .iter()
            .filter(|entry| entry.file_type != "dir")
            .count(),
    })
}

fn remove_package_from_root(
    database_path: &Path,
    package: &InstalledPackageRecord,
    target_root: &Path,
) -> Result<usize, AppError> {
    let paths = list_installed_files_for_package(database_path, &package.name)?;
    let count = paths.len();
    remove_paths_from_root(&paths, target_root)?;
    Ok(count)
}

fn remove_paths_from_root(paths: &[String], target_root: &Path) -> Result<(), AppError> {
    let mut ordered = paths.to_vec();
    ordered.sort_by(|left, right| {
        right
            .matches('/')
            .count()
            .cmp(&left.matches('/').count())
            .then_with(|| right.len().cmp(&left.len()))
    });
    for path in ordered {
        let target = root_path(target_root, &path);
        if !path_exists(&target) {
            continue;
        }
        remove_existing_path(&target)?;
        cleanup_empty_parent_dirs(target.parent(), target_root)?;
    }
    Ok(())
}

fn cleanup_empty_parent_dirs(
    mut current: Option<&Path>,
    target_root: &Path,
) -> Result<(), AppError> {
    while let Some(path) = current {
        if path == target_root {
            break;
        }
        match fs::read_dir(path) {
            Ok(mut entries) => {
                if entries.next().is_some() {
                    break;
                }
                fs::remove_dir(path).map_err(|source| AppError::Io {
                    path: path.to_path_buf(),
                    source,
                })?;
                current = path.parent();
            }
            Err(source) => {
                return Err(AppError::Io {
                    path: path.to_path_buf(),
                    source,
                });
            }
        }
    }
    Ok(())
}

fn compute_removal_plan(
    package_name: &str,
    installed: &HashMap<String, InstalledPackageRecord>,
    remaining_world: &[WorldEntry],
    dependencies: &[sloppkg_db::InstalledDependencyRecord],
) -> Result<Vec<PreparedRemoval>, AppError> {
    if !installed.contains_key(package_name) {
        return Err(AppError::PackageNotInstalled(package_name.to_owned()));
    }

    let remaining_world_names = remaining_world
        .iter()
        .map(|entry| entry.package_name.clone())
        .collect::<HashSet<_>>();
    let mut dependencies_by_package = HashMap::<String, Vec<String>>::new();
    let mut dependents_by_dependency = HashMap::<String, BTreeSet<String>>::new();
    for edge in dependencies {
        dependencies_by_package
            .entry(edge.package_name.clone())
            .or_default()
            .push(edge.dependency_name.clone());
        dependents_by_dependency
            .entry(edge.dependency_name.clone())
            .or_default()
            .insert(edge.package_name.clone());
    }

    let direct_dependents = dependents_by_dependency
        .get(package_name)
        .cloned()
        .unwrap_or_default();
    if !direct_dependents.is_empty() {
        let dependents = direct_dependents.into_iter().collect::<Vec<_>>();
        return Err(AppError::ReverseDependencyBlocked {
            package: package_name.to_owned(),
            dependents: dependents.join(", "),
        });
    }

    let mut removal_names = Vec::new();
    let mut queued = HashSet::new();
    removal_names.push(package_name.to_owned());
    queued.insert(package_name.to_owned());

    let mut cursor = 0;
    while cursor < removal_names.len() {
        let current = removal_names[cursor].clone();
        cursor += 1;
        for dependency_name in dependencies_by_package
            .get(&current)
            .cloned()
            .unwrap_or_default()
        {
            if queued.contains(&dependency_name) {
                continue;
            }
            let Some(candidate) = installed.get(&dependency_name) else {
                continue;
            };
            if candidate.install_reason != "auto"
                || remaining_world_names.contains(&dependency_name)
            {
                continue;
            }
            let remaining_dependents = dependents_by_dependency
                .get(&dependency_name)
                .into_iter()
                .flatten()
                .filter(|dependent| !queued.contains(*dependent))
                .count();
            if remaining_dependents == 0 {
                queued.insert(dependency_name.clone());
                removal_names.push(dependency_name);
            }
        }
    }

    Ok(removal_names
        .into_iter()
        .map(|name| PreparedRemoval {
            action: if name == package_name {
                String::from("remove")
            } else {
                String::from("autoremove")
            },
            package: installed.get(&name).cloned().unwrap(),
        })
        .collect())
}

fn root_path(target_root: &Path, manifest_path: &str) -> PathBuf {
    target_root.join(manifest_path.trim_start_matches('/'))
}

fn copy_tree_into(source: &Path, destination: &Path) -> Result<(), AppError> {
    fs::create_dir_all(destination).map_err(|source_err| AppError::Io {
        path: destination.to_path_buf(),
        source: source_err,
    })?;
    for entry in fs::read_dir(source).map_err(|source_err| AppError::Io {
        path: source.to_path_buf(),
        source: source_err,
    })? {
        let entry = entry.map_err(|source_err| AppError::Io {
            path: source.to_path_buf(),
            source: source_err,
        })?;
        let source_path = entry.path();
        let destination_path = destination.join(entry.file_name());
        let metadata = fs::symlink_metadata(&source_path).map_err(|source_err| AppError::Io {
            path: source_path.clone(),
            source: source_err,
        })?;

        if metadata.file_type().is_dir() {
            copy_tree_into(&source_path, &destination_path)?;
        } else if metadata.file_type().is_symlink() {
            if path_exists(&destination_path) {
                remove_existing_path(&destination_path)?;
            }
            let target = fs::read_link(&source_path).map_err(|source_err| AppError::Io {
                path: source_path.clone(),
                source: source_err,
            })?;
            if let Some(parent) = destination_path.parent() {
                fs::create_dir_all(parent).map_err(|source_err| AppError::Io {
                    path: parent.to_path_buf(),
                    source: source_err,
                })?;
            }
            symlink(&target, &destination_path).map_err(|source_err| AppError::Io {
                path: destination_path.clone(),
                source: source_err,
            })?;
        } else {
            if let Some(parent) = destination_path.parent() {
                fs::create_dir_all(parent).map_err(|source_err| AppError::Io {
                    path: parent.to_path_buf(),
                    source: source_err,
                })?;
            }
            if path_exists(&destination_path) {
                remove_existing_path(&destination_path)?;
            }
            fs::copy(&source_path, &destination_path).map_err(|source_err| AppError::Io {
                path: destination_path.clone(),
                source: source_err,
            })?;
            fs::set_permissions(
                &destination_path,
                fs::Permissions::from_mode(metadata.permissions().mode()),
            )
            .map_err(|source_err| AppError::Io {
                path: destination_path.clone(),
                source: source_err,
            })?;
        }
    }
    Ok(())
}

fn remove_existing_path(path: &Path) -> Result<(), AppError> {
    let metadata = fs::symlink_metadata(path).map_err(|source| AppError::Io {
        path: path.to_path_buf(),
        source,
    })?;
    if metadata.file_type().is_dir() {
        fs::remove_dir_all(path).map_err(|source| AppError::Io {
            path: path.to_path_buf(),
            source,
        })?;
    } else {
        fs::remove_file(path).map_err(|source| AppError::Io {
            path: path.to_path_buf(),
            source,
        })?;
    }
    Ok(())
}

fn path_exists(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok()
}

fn sanitize(input: &str) -> String {
    input
        .chars()
        .map(|ch| if ch.is_ascii_alphanumeric() { ch } else { '-' })
        .collect()
}

fn publish_revision_string() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    format!("{:020}-{:09}", now.as_secs(), now.subsec_nanos())
}

fn normalize_prefix(prefix: &str) -> String {
    if prefix == "/" {
        String::from("/")
    } else {
        format!("/{}", prefix.trim_matches('/'))
    }
}

fn path_within_prefix(path: &str, prefix: &str) -> bool {
    if prefix == "/" {
        path.starts_with('/')
    } else {
        path == prefix || path.starts_with(&format!("{prefix}/"))
    }
}

fn format_evr_parts(epoch: u64, version: &str, release: &str) -> String {
    if epoch == 0 {
        format!("{version}-{release}")
    } else {
        format!("{epoch}:{version}-{release}")
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::os::unix::fs::PermissionsExt;
    use std::path::Path;
    use std::thread;
    use std::time::{SystemTime, UNIX_EPOCH};

    use sha2::{Digest, Sha256};
    use sloppkg_db::{
        create_transaction, list_installed_packages, list_transaction_statuses,
        update_transaction_status,
    };
    use sloppkg_types::{
        ManifestEntry, PackageManifest, RepoConfigEntry, RepoKind, RepoSyncStrategy, RepoTrustMode,
    };

    use super::{
        format_bootstrap_progress, installable_manifest, normalize_existing_path, normalize_prefix,
        path_within_prefix, render_progress_bar, App, AppError, AppPaths, BootstrapProgress,
        CleanupTarget, PublishState, RepoPublishOptions, TransactionOptions,
    };

    fn write_runtime_hook(path: &Path, body: &str) {
        fs::write(path, body).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
    }

    #[test]
    fn root_runtime_maintenance_runs_present_scripts_in_order() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("sloppkg-core-maintenance-order-{unique}"));
        let state_root = root.join("state");
        let initd = root.join("etc/init.d");
        let log_path = root.join("maintenance.log");
        fs::create_dir_all(&initd).unwrap();

        for name in [
            "S14persistent-dropbear",
            "S15local-lib-links",
            "S16persistent-sloppkg",
            "S17persistent-getty",
            "S19persistent-sh",
            "S20managed-userland-links",
        ] {
            write_runtime_hook(
                &initd.join(name),
                &format!(
                    "#!/bin/sh\nset -eu\nprintf '%s\\n' '{name}' >> '{}'\n",
                    log_path.display()
                ),
            );
        }

        let app = App::new(AppPaths::from_state_root(state_root));
        app.run_root_runtime_maintenance(&root).unwrap();

        assert_eq!(
            fs::read_to_string(&log_path).unwrap(),
            "S14persistent-dropbear\nS15local-lib-links\nS16persistent-sloppkg\nS17persistent-getty\nS19persistent-sh\nS20managed-userland-links\n"
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn root_runtime_maintenance_reports_failing_script() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("sloppkg-core-maintenance-fail-{unique}"));
        let state_root = root.join("state");
        let initd = root.join("etc/init.d");
        fs::create_dir_all(&initd).unwrap();

        write_runtime_hook(
            &initd.join("S15local-lib-links"),
            "#!/bin/sh\nset -eu\nexit 23\n",
        );

        let app = App::new(AppPaths::from_state_root(state_root));
        let err = app.run_root_runtime_maintenance(&root).unwrap_err();
        match err {
            AppError::MaintenanceCommandFailed { command, status } => {
                assert!(command.ends_with("etc/init.d/S15local-lib-links"));
                assert_eq!(status, "exit code 23");
            }
            other => panic!("unexpected error: {other:?}"),
        }

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn installable_manifest_accepts_multiple_owned_prefixes() {
        let manifest = PackageManifest {
            package_name: String::from("toolchain-gcc"),
            version: String::from("14.3.0-1"),
            entries: vec![
                ManifestEntry {
                    path: String::from("/usr/bin/gcc"),
                    file_type: String::from("symlink"),
                    mode: 0o777,
                    size: 0,
                    sha256: None,
                    link_target: Some(String::from(
                        "/Volumes/slopos-data/toolchain/selfhost-final/bin/selfhost-gcc",
                    )),
                    config_file: false,
                },
                ManifestEntry {
                    path: String::from(
                        "/Volumes/slopos-data/toolchain/selfhost-final/bin/selfhost-gcc",
                    ),
                    file_type: String::from("file"),
                    mode: 0o755,
                    size: 1,
                    sha256: Some(String::from("abc")),
                    link_target: None,
                    config_file: false,
                },
            ],
        };

        let filtered = installable_manifest(
            &manifest,
            &[
                String::from("/usr/bin"),
                String::from("/Volumes/slopos-data/toolchain"),
            ],
        )
        .unwrap();

        assert_eq!(filtered.entries.len(), 2);
    }

    #[test]
    fn installable_manifest_rejects_paths_outside_owned_prefixes() {
        let manifest = PackageManifest {
            package_name: String::from("toolchain-gcc"),
            version: String::from("14.3.0-1"),
            entries: vec![ManifestEntry {
                path: String::from("/etc/profile"),
                file_type: String::from("file"),
                mode: 0o644,
                size: 1,
                sha256: Some(String::from("abc")),
                link_target: None,
                config_file: false,
            }],
        };

        assert!(installable_manifest(&manifest, &[String::from("/usr/bin")]).is_err());
    }

    #[test]
    fn prefix_helpers_normalize_and_match_paths() {
        assert_eq!(normalize_prefix("usr/bin"), "/usr/bin");
        assert!(path_within_prefix("/usr/bin/gcc", "/usr/bin"));
        assert!(!path_within_prefix("/usr/lib/libc.so", "/usr/bin"));
    }

    #[test]
    fn bootstrap_progress_bar_renders_expected_shape() {
        assert_eq!(render_progress_bar(0, 4, 8), "[>-------]");
        assert_eq!(render_progress_bar(2, 4, 8), "[====>---]");
        assert_eq!(render_progress_bar(4, 4, 8), "[========]");
    }

    #[test]
    fn bootstrap_progress_format_includes_stage_and_package_counts() {
        let progress = BootstrapProgress {
            total_stages: 6,
            total_packages: 9,
            completed_stages: 2,
            completed_packages: 3,
        };
        let line = format_bootstrap_progress(&progress, "stage 3/6 selfhost-gcc-stage2");
        assert!(line.contains("stages 2/6"));
        assert!(line.contains("packages 3/9"));
        assert!(line.contains("selfhost-gcc-stage2"));
    }

    #[test]
    fn install_runs_bootstrap_stages_before_cache_install() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("sloppkg-core-bootstrap-test-{unique}"));
        let state_root = root.join("state");
        let repo_root = root.join("repo");
        let packages_root = repo_root.join("packages");
        let sysroot = root.join("bootstrap-sysroot");

        fs::create_dir_all(&packages_root).unwrap();
        fs::write(
            repo_root.join("repo.toml"),
            "name = \"workspace\"\nkind = \"recipe\"\n",
        )
        .unwrap();

        write_test_package(
            &packages_root,
            "bootstrap-a",
            "0.1.0",
            1,
            &format!(
                r#"[package]
name = "bootstrap-a"
version = "0.1.0"
release = 1
summary = "bootstrap a"
description = "bootstrap a"
license = "MIT"
architectures = ["aarch64"]

[[sources]]
kind = "file"
url = "build.sh"
sha256 = "local"
destination = "build.sh"

[build]
system = "custom"
out_of_tree = true
install = ["bash \"$PKG_SOURCE_DIR/build.sh\""]

[install]
prefix = "{sysroot}"
owned_prefixes = ["{sysroot}"]
"#,
                sysroot = sysroot.display()
            ),
            r#"#!/bin/bash
set -euo pipefail
: "${BOOTSTRAP_SYSROOT:?}"
dest="$PKG_DESTDIR$BOOTSTRAP_SYSROOT/stage1"
mkdir -p "$dest"
printf 'stage1\n' > "$dest/marker.txt"
"#,
        );

        write_test_package(
            &packages_root,
            "bootstrap-b",
            "0.1.0",
            1,
            &format!(
                r#"[package]
name = "bootstrap-b"
version = "0.1.0"
release = 1
summary = "bootstrap b"
description = "bootstrap b"
license = "MIT"
architectures = ["aarch64"]

[[sources]]
kind = "file"
url = "build.sh"
sha256 = "local"
destination = "build.sh"

[build]
system = "custom"
out_of_tree = true
install = ["bash \"$PKG_SOURCE_DIR/build.sh\""]

[install]
prefix = "{sysroot}"
owned_prefixes = ["{sysroot}"]

[[dependencies]]
name = "bootstrap-a"
constraint = ">= 0.1.0-1"
kind = "build"

[[dependencies]]
name = "bootstrap-a"
constraint = ">= 0.1.0-1"
kind = "runtime"
"#,
                sysroot = sysroot.display()
            ),
            r#"#!/bin/bash
set -euo pipefail
: "${BOOTSTRAP_SYSROOT:?}"
marker="$BOOTSTRAP_SYSROOT/stage1/marker.txt"
if [[ ! -f "$marker" ]]; then
  echo "missing bootstrap marker at $marker" >&2
  exit 1
fi
dest="$PKG_DESTDIR$BOOTSTRAP_SYSROOT/stage2"
mkdir -p "$dest"
cp "$marker" "$dest/copied-marker.txt"
"#,
        );

        write_test_package(
            &packages_root,
            "bootstrap-world",
            "0.1.0",
            1,
            &format!(
                r#"[package]
name = "bootstrap-world"
version = "0.1.0"
release = 1
summary = "bootstrap world"
description = "bootstrap world"
license = "MIT"
architectures = ["aarch64"]

[build]
system = "custom"
out_of_tree = true

[install]
prefix = "/usr/local"
owned_prefixes = ["/usr/local"]

[bootstrap]
sysroot = "{sysroot}"

[[bootstrap.stages]]
name = "stage1"
packages = ["bootstrap-a"]
env = {{ BOOTSTRAP_SYSROOT = "{sysroot}" }}

[[bootstrap.stages]]
name = "stage2"
packages = ["bootstrap-b"]
depends_on = ["stage1"]
env = {{ BOOTSTRAP_SYSROOT = "{sysroot}" }}

[[bootstrap.stages]]
name = "stage3"
packages = ["bootstrap-world"]
depends_on = ["stage2"]
env = {{ BOOTSTRAP_SYSROOT = "{sysroot}" }}

[[dependencies]]
name = "bootstrap-a"
constraint = ">= 0.1.0-1"
kind = "runtime"

[[dependencies]]
name = "bootstrap-b"
constraint = ">= 0.1.0-1"
kind = "runtime"
"#,
                sysroot = sysroot.display()
            ),
            "#!/bin/bash\nset -euo pipefail\n",
        );

        let app = App::new(AppPaths::from_state_root(state_root.clone()));
        let report = app
            .install(Some(&repo_root), "bootstrap-world", "*", Path::new("/"))
            .unwrap();

        assert_eq!(report.packages.len(), 3);
        assert_eq!(
            fs::read_to_string(sysroot.join("stage1/marker.txt")).unwrap(),
            "stage1\n"
        );
        assert_eq!(
            fs::read_to_string(sysroot.join("stage2/copied-marker.txt")).unwrap(),
            "stage1\n"
        );

        let stamp_dir = state_root
            .join("db/bootstrap-stamps")
            .join("bootstrap-world");
        assert!(stamp_dir.join("stage1.done").exists());
        assert!(stamp_dir.join("stage2.done").exists());
        assert!(stamp_dir.join("stage3.done").exists());

        let installed = list_installed_packages(&state_root.join("db/state.sqlite")).unwrap();
        let installed_names = installed
            .into_iter()
            .map(|package| package.name)
            .collect::<Vec<_>>();
        assert!(installed_names.contains(&String::from("bootstrap-a")));
        assert!(installed_names.contains(&String::from("bootstrap-b")));
        assert!(installed_names.contains(&String::from("bootstrap-world")));

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn upgrade_reruns_bootstrap_for_world_packages() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("sloppkg-core-bootstrap-upgrade-{unique}"));
        let state_root = root.join("state");
        let repo_root = root.join("repo");
        let packages_root = repo_root.join("packages");
        let sysroot = root.join("bootstrap-sysroot");

        fs::create_dir_all(&packages_root).unwrap();
        fs::write(
            repo_root.join("repo.toml"),
            "name = \"workspace\"\nkind = \"recipe\"\n",
        )
        .unwrap();

        write_test_package(
            &packages_root,
            "bootstrap-a",
            "0.1.0",
            1,
            &format!(
                r#"[package]
name = "bootstrap-a"
version = "0.1.0"
release = 1
summary = "bootstrap a"
description = "bootstrap a"
license = "MIT"
architectures = ["aarch64"]

[[sources]]
kind = "file"
url = "build.sh"
sha256 = "local"
destination = "build.sh"

[build]
system = "custom"
out_of_tree = true
install = ["bash \"$PKG_SOURCE_DIR/build.sh\""]

[install]
prefix = "{sysroot}"
owned_prefixes = ["{sysroot}"]
"#,
                sysroot = sysroot.display()
            ),
            r#"#!/bin/bash
set -euo pipefail
: "${BOOTSTRAP_SYSROOT:?}"
dest="$PKG_DESTDIR$BOOTSTRAP_SYSROOT/stage1"
mkdir -p "$dest"
printf 'stage1\n' > "$dest/marker.txt"
"#,
        );

        write_test_package(
            &packages_root,
            "bootstrap-b",
            "0.1.0",
            1,
            &format!(
                r#"[package]
name = "bootstrap-b"
version = "0.1.0"
release = 1
summary = "bootstrap b"
description = "bootstrap b"
license = "MIT"
architectures = ["aarch64"]

[[sources]]
kind = "file"
url = "build.sh"
sha256 = "local"
destination = "build.sh"

[build]
system = "custom"
out_of_tree = true
install = ["bash \"$PKG_SOURCE_DIR/build.sh\""]

[install]
prefix = "{sysroot}"
owned_prefixes = ["{sysroot}"]

[[dependencies]]
name = "bootstrap-a"
constraint = ">= 0.1.0-1"
kind = "build"

[[dependencies]]
name = "bootstrap-a"
constraint = ">= 0.1.0-1"
kind = "runtime"
"#,
                sysroot = sysroot.display()
            ),
            r#"#!/bin/bash
set -euo pipefail
: "${BOOTSTRAP_SYSROOT:?}"
marker="$BOOTSTRAP_SYSROOT/stage1/marker.txt"
if [[ ! -f "$marker" ]]; then
  echo "missing bootstrap marker at $marker" >&2
  exit 1
fi
dest="$PKG_DESTDIR$BOOTSTRAP_SYSROOT/stage2"
mkdir -p "$dest"
cp "$marker" "$dest/copied-marker.txt"
"#,
        );

        write_test_package(
            &packages_root,
            "bootstrap-world",
            "0.1.0",
            1,
            &format!(
                r#"[package]
name = "bootstrap-world"
version = "0.1.0"
release = 1
summary = "bootstrap world"
description = "bootstrap world"
license = "MIT"
architectures = ["aarch64"]

[build]
system = "custom"
out_of_tree = true

[install]
prefix = "/usr/local"
owned_prefixes = ["/usr/local"]

[bootstrap]
sysroot = "{sysroot}"

[[bootstrap.stages]]
name = "stage1"
packages = ["bootstrap-a"]
env = {{ BOOTSTRAP_SYSROOT = "{sysroot}" }}

[[bootstrap.stages]]
name = "stage2"
packages = ["bootstrap-b"]
depends_on = ["stage1"]
env = {{ BOOTSTRAP_SYSROOT = "{sysroot}" }}

[[bootstrap.stages]]
name = "stage3"
packages = ["bootstrap-world"]
depends_on = ["stage2"]
env = {{ BOOTSTRAP_SYSROOT = "{sysroot}" }}

[[dependencies]]
name = "bootstrap-a"
constraint = ">= 0.1.0-1"
kind = "runtime"

[[dependencies]]
name = "bootstrap-b"
constraint = ">= 0.1.0-1"
kind = "runtime"
"#,
                sysroot = sysroot.display()
            ),
            "#!/bin/bash\nset -euo pipefail\n",
        );

        let app = App::new(AppPaths::from_state_root(state_root.clone()));
        app.install(Some(&repo_root), "bootstrap-world", "*", Path::new("/"))
            .unwrap();

        fs::remove_file(
            state_root.join("packages/bootstrap-a/bootstrap-a-0.1.0-1-aarch64.sloppkg.tar.zst"),
        )
        .unwrap();
        fs::remove_file(
            state_root.join("packages/bootstrap-b/bootstrap-b-0.1.0-1-aarch64.sloppkg.tar.zst"),
        )
        .unwrap();
        fs::write(
            packages_root.join("bootstrap-a/0.1.0-1/build.sh"),
            r#"#!/bin/bash
set -euo pipefail
: "${BOOTSTRAP_SYSROOT:?}"
dest="$PKG_DESTDIR$BOOTSTRAP_SYSROOT/stage1"
mkdir -p "$dest"
printf 'stage1-updated\n' > "$dest/marker.txt"
"#,
        )
        .unwrap();

        app.upgrade(Some(&repo_root), Path::new("/")).unwrap();
        assert_eq!(
            fs::read_to_string(sysroot.join("stage2/copied-marker.txt")).unwrap(),
            "stage1-updated\n"
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn update_syncs_unified_repo_into_local_snapshot() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("sloppkg-core-update-test-{unique}"));
        let remote_root = root.join("remote");
        let state_root = root.join("state");
        fs::create_dir_all(remote_root.join("recipes/by-name/remote-hello/0.1.0-1")).unwrap();

        let package_toml = r#"[package]
name = "remote-hello"
version = "0.1.0"
release = 1
summary = "remote hello"
description = "remote hello"
license = "MIT"
architectures = ["aarch64"]

[build]
system = "custom"
out_of_tree = true
install = [
  "mkdir -p \"$PKG_DESTDIR/usr/local/bin\"",
  "printf '#!/bin/sh\necho remote\\n' > \"$PKG_DESTDIR/usr/local/bin/remote-hello\"",
  "chmod 0755 \"$PKG_DESTDIR/usr/local/bin/remote-hello\""
]

[install]
prefix = "/usr/local"
owned_prefixes = ["/usr/local"]
"#;
        let package_sha = sha256_hex(package_toml.as_bytes());

        let manifest_toml = format!(
            r#"format_version = 1
package_name = "remote-hello"
version = "0.1.0"
release = "1"

[[files]]
path = "package.toml"
sha256 = "{package_sha}"
"#
        );
        let manifest_sha = sha256_hex(manifest_toml.as_bytes());

        let index_toml = format!(
            r#"format_version = 1
repo_name = "slopos-main"
channel = "stable"
revision = "2026.03.26"
generated_at = "2026-03-26T00:00:00Z"

[[recipes]]
name = "remote-hello"

[[recipes.versions]]
version = "0.1.0"
release = "1"
manifest_path = "recipes/by-name/remote-hello/0.1.0-1/manifest.toml"
manifest_sha256 = "{manifest_sha}"
"#
        );
        let index_sha = sha256_hex(index_toml.as_bytes());

        let repo_toml = format!(
            r#"format_version = 1
name = "slopos-main"
kind = "unified"
generated_at = "2026-03-26T00:00:00Z"
default_channel = "stable"
capabilities = ["recipes"]

[recipes.channels.stable]
current_revision = "2026.03.26"
index_path = "recipes/index/stable.toml"
index_sha256 = "{index_sha}"

[trust]
mode = "digest-pinned"
"#
        );

        fs::create_dir_all(remote_root.join("recipes/index")).unwrap();
        fs::write(remote_root.join("repo.toml"), repo_toml).unwrap();
        fs::write(remote_root.join("recipes/index/stable.toml"), index_toml).unwrap();
        fs::write(
            remote_root.join("recipes/by-name/remote-hello/0.1.0-1/manifest.toml"),
            manifest_toml,
        )
        .unwrap();
        fs::write(
            remote_root.join("recipes/by-name/remote-hello/0.1.0-1/package.toml"),
            package_toml,
        )
        .unwrap();

        let server = TestHttpServer::start(remote_root.clone(), 4);
        let app = App::new(AppPaths::from_state_root(state_root.clone()));
        app.add_repo(RepoConfigEntry {
            name: String::from("main"),
            kind: RepoKind::Unified,
            url: server.base_url(),
            channel: Some(String::from("stable")),
            priority: 50,
            enabled: true,
            trust_policy: RepoTrustMode::DigestPinned,
            sync_strategy: RepoSyncStrategy::StaticHttp,
        })
        .unwrap();

        let update = app.update(None, None).unwrap();
        assert_eq!(update.repos.len(), 1);
        assert_eq!(update.repos[0].action, "updated");
        assert_eq!(update.repos[0].package_count, 1);

        let doctor = app.doctor(None).unwrap();
        assert_eq!(doctor.repo_count, 1);
        assert_eq!(doctor.packages_loaded, 1);

        let plan = app.resolve(None, "remote-hello", "*").unwrap();
        assert_eq!(plan.packages.len(), 1);
        assert!(plan.packages[0]
            .package
            .source_path
            .display()
            .to_string()
            .contains("packages/remote-hello/0.1.0-1/package.toml"));
        assert!(update.repos[0]
            .snapshot_root
            .as_ref()
            .unwrap()
            .join("packages/remote-hello/0.1.0-1/package.toml")
            .exists());

        server.join();
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn upgrade_rebuilds_world_package_when_recipe_changes_without_version_bump() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("sloppkg-core-upgrade-rebuild-{unique}"));
        let state_root = root.join("state");
        let repo_root = root.join("repo");
        let packages_root = repo_root.join("packages");
        let target_root = root.join("target");

        fs::create_dir_all(&packages_root).unwrap();
        fs::write(
            repo_root.join("repo.toml"),
            "name = \"workspace\"\nkind = \"recipe\"\n",
        )
        .unwrap();

        write_test_package(
            &packages_root,
            "hello-tool",
            "0.1.0",
            1,
            r#"[package]
name = "hello-tool"
version = "0.1.0"
release = 1
summary = "hello tool"
description = "hello tool"
license = "MIT"
architectures = ["aarch64"]

[[sources]]
kind = "file"
url = "hello.txt"
sha256 = "local"
destination = "hello.txt"

[build]
system = "custom"
out_of_tree = true
install = [
  "mkdir -p \"$PKG_DESTDIR/usr/local/bin\"",
  "install -m 0755 \"$PKG_SOURCE_DIR/hello.txt\" \"$PKG_DESTDIR/usr/local/bin/hello-tool\""
]

[install]
prefix = "/usr/local"
owned_prefixes = ["/usr/local"]
"#,
            "#!/bin/sh\necho first\n",
        );
        fs::write(
            packages_root.join("hello-tool/0.1.0-1").join("hello.txt"),
            "#!/bin/sh\necho first\n",
        )
        .unwrap();

        let app = App::new(AppPaths::from_state_root(state_root.clone()));
        app.install(Some(&repo_root), "hello-tool", "*", &target_root)
            .unwrap();
        assert_eq!(
            fs::read_to_string(target_root.join("usr/local/bin/hello-tool")).unwrap(),
            "#!/bin/sh\necho first\n"
        );

        fs::write(
            packages_root.join("hello-tool/0.1.0-1").join("hello.txt"),
            "#!/bin/sh\necho second\n",
        )
        .unwrap();

        app.upgrade(Some(&repo_root), &target_root).unwrap();
        assert_eq!(
            fs::read_to_string(target_root.join("usr/local/bin/hello-tool")).unwrap(),
            "#!/bin/sh\necho second\n"
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn explicit_recipe_root_overrides_configured_repos() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("sloppkg-core-recipe-root-override-{unique}"));
        let state_root = root.join("state");
        let configured_repo = root.join("configured-repo");
        let configured_packages = configured_repo.join("packages");
        let override_repo = root.join("override-repo");
        let override_packages = override_repo.join("packages");
        let target_root = root.join("target");

        fs::create_dir_all(&configured_packages).unwrap();
        fs::create_dir_all(&override_packages).unwrap();
        fs::write(
            configured_repo.join("repo.toml"),
            "name = \"configured\"\nkind = \"recipe\"\n",
        )
        .unwrap();
        fs::write(
            override_repo.join("repo.toml"),
            "name = \"override\"\nkind = \"recipe\"\n",
        )
        .unwrap();

        let package_toml = r#"[package]
name = "hello-tool"
version = "0.1.0"
release = 1
summary = "hello tool"
description = "hello tool"
license = "MIT"
architectures = ["aarch64"]

[[sources]]
kind = "file"
url = "hello.txt"
sha256 = "local"
destination = "hello.txt"

[build]
system = "custom"
out_of_tree = true
install = [
  "mkdir -p \"$PKG_DESTDIR/usr/local/bin\"",
  "install -m 0755 \"$PKG_SOURCE_DIR/hello.txt\" \"$PKG_DESTDIR/usr/local/bin/hello-tool\""
]

[install]
prefix = "/usr/local"
owned_prefixes = ["/usr/local"]
"#;

        write_test_package(
            &configured_packages,
            "hello-tool",
            "0.1.0",
            1,
            package_toml,
            "#!/bin/sh\necho configured\n",
        );
        fs::write(
            configured_packages
                .join("hello-tool/0.1.0-1")
                .join("hello.txt"),
            "#!/bin/sh\necho configured\n",
        )
        .unwrap();

        write_test_package(
            &override_packages,
            "hello-tool",
            "0.1.0",
            1,
            package_toml,
            "#!/bin/sh\necho override\n",
        );
        fs::write(
            override_packages
                .join("hello-tool/0.1.0-1")
                .join("hello.txt"),
            "#!/bin/sh\necho override\n",
        )
        .unwrap();

        let app = App::new(AppPaths::from_state_root(state_root.clone()));
        app.add_repo(RepoConfigEntry {
            name: String::from("configured"),
            kind: RepoKind::Recipe,
            url: configured_repo.display().to_string(),
            channel: None,
            priority: 50,
            enabled: true,
            trust_policy: RepoTrustMode::Local,
            sync_strategy: RepoSyncStrategy::File,
        })
        .unwrap();

        app.install(Some(&override_repo), "hello-tool", "*", &target_root)
            .unwrap();
        assert_eq!(
            fs::read_to_string(target_root.join("usr/local/bin/hello-tool")).unwrap(),
            "#!/bin/sh\necho override\n"
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn dependents_report_tracks_direct_and_transitive_installed_dependents() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("sloppkg-core-dependents-{unique}"));
        let state_root = root.join("state");
        let repo_root = root.join("repo");
        let packages_root = repo_root.join("packages");
        let target_root = root.join("target");

        fs::create_dir_all(&packages_root).unwrap();
        fs::write(
            repo_root.join("repo.toml"),
            "name = \"workspace\"\nkind = \"recipe\"\n",
        )
        .unwrap();

        let shared_install = r#"[build]
system = "custom"
out_of_tree = true
install = [
  "mkdir -p \"$PKG_DESTDIR/usr/local/bin\"",
  "install -m 0755 \"$PKG_SOURCE_DIR/tool.sh\" \"$PKG_DESTDIR/usr/local/bin/PLACEHOLDER\""
]

[install]
prefix = "/usr/local"
owned_prefixes = ["/usr/local"]
"#;

        write_test_package(
            &packages_root,
            "libalpha",
            "0.1.0",
            1,
            &format!(
                r#"[package]
name = "libalpha"
version = "0.1.0"
release = 1
summary = "libalpha"
description = "libalpha"
license = "MIT"
architectures = ["aarch64"]

[[sources]]
kind = "file"
url = "tool.sh"
sha256 = "local"
destination = "tool.sh"

{}
"#,
                shared_install.replace("PLACEHOLDER", "libalpha")
            ),
            "#!/bin/sh\necho libalpha\n",
        );
        fs::write(
            packages_root.join("libalpha/0.1.0-1").join("tool.sh"),
            "#!/bin/sh\necho libalpha\n",
        )
        .unwrap();

        write_test_package(
            &packages_root,
            "app-one",
            "0.1.0",
            1,
            &format!(
                r#"[package]
name = "app-one"
version = "0.1.0"
release = 1
summary = "app-one"
description = "app-one"
license = "MIT"
architectures = ["aarch64"]

[[sources]]
kind = "file"
url = "tool.sh"
sha256 = "local"
destination = "tool.sh"

[[dependencies]]
name = "libalpha"
constraint = "*"
kind = "runtime"

{}
"#,
                shared_install.replace("PLACEHOLDER", "app-one")
            ),
            "#!/bin/sh\necho app-one\n",
        );
        fs::write(
            packages_root.join("app-one/0.1.0-1").join("tool.sh"),
            "#!/bin/sh\necho app-one\n",
        )
        .unwrap();

        write_test_package(
            &packages_root,
            "app-two",
            "0.1.0",
            1,
            &format!(
                r#"[package]
name = "app-two"
version = "0.1.0"
release = 1
summary = "app-two"
description = "app-two"
license = "MIT"
architectures = ["aarch64"]

[[sources]]
kind = "file"
url = "tool.sh"
sha256 = "local"
destination = "tool.sh"

[[dependencies]]
name = "app-one"
constraint = "*"
kind = "runtime"

{}
"#,
                shared_install.replace("PLACEHOLDER", "app-two")
            ),
            "#!/bin/sh\necho app-two\n",
        );
        fs::write(
            packages_root.join("app-two/0.1.0-1").join("tool.sh"),
            "#!/bin/sh\necho app-two\n",
        )
        .unwrap();

        let app = App::new(AppPaths::from_state_root(state_root.clone()));
        app.install(Some(&repo_root), "app-two", "*", &target_root)
            .unwrap();

        let direct = app.dependents("libalpha", false).unwrap();
        assert_eq!(direct.packages.len(), 1);
        assert_eq!(direct.packages[0].package_name, "app-one");
        assert!(direct.packages[0].direct);
        assert_eq!(direct.packages[0].depth, 1);
        assert_eq!(direct.packages[0].install_reason, "auto");
        assert!(!direct.packages[0].world_member);

        let transitive = app.dependents("libalpha", true).unwrap();
        assert_eq!(
            transitive
                .packages
                .iter()
                .map(|package| package.package_name.as_str())
                .collect::<Vec<_>>(),
            vec!["app-one", "app-two"]
        );
        assert_eq!(transitive.packages[1].depth, 2);
        assert_eq!(transitive.packages[1].install_reason, "explicit");
        assert!(transitive.packages[1].world_member);

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn cache_status_reports_missing_ready_and_stale_recipe_matches() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("sloppkg-core-cache-status-{unique}"));
        let state_root = root.join("state");
        let repo_root = root.join("repo");
        let packages_root = repo_root.join("packages");

        fs::create_dir_all(&packages_root).unwrap();
        fs::write(
            repo_root.join("repo.toml"),
            "name = \"workspace\"\nkind = \"recipe\"\n",
        )
        .unwrap();
        write_test_package(
            &packages_root,
            "hello-tool",
            "0.1.0",
            1,
            r#"[package]
name = "hello-tool"
version = "0.1.0"
release = 1
summary = "hello tool"
description = "hello tool"
license = "MIT"
architectures = ["aarch64"]

[[sources]]
kind = "file"
url = "hello.txt"
sha256 = "local"
destination = "hello.txt"

[build]
system = "custom"
out_of_tree = true
install = [
  "mkdir -p \"$PKG_DESTDIR/usr/local/bin\"",
  "install -m 0755 \"$PKG_SOURCE_DIR/hello.txt\" \"$PKG_DESTDIR/usr/local/bin/hello-tool\""
]

[install]
prefix = "/usr/local"
owned_prefixes = ["/usr/local"]
"#,
            "#!/bin/sh\necho first\n",
        );
        let hello_txt = packages_root.join("hello-tool/0.1.0-1/hello.txt");
        fs::write(&hello_txt, "#!/bin/sh\necho first\n").unwrap();

        let app = App::new(AppPaths::from_state_root(state_root.clone()));

        let missing = app
            .cache_status(Some(&repo_root), "hello-tool", "*")
            .unwrap();
        assert_eq!(missing.status, "missing");
        assert!(missing.archive_path.is_none());

        let build = app.build(Some(&repo_root), "hello-tool", "*").unwrap();
        let ready = app
            .cache_status(Some(&repo_root), "hello-tool", "*")
            .unwrap();
        assert_eq!(ready.status, "ready");
        assert_eq!(
            normalize_existing_path(ready.archive_path.as_ref().unwrap()),
            normalize_existing_path(&build.package_archive_path)
        );
        assert_eq!(
            ready.archive_sha256.as_deref(),
            Some(build.package_archive_sha256.as_str())
        );

        fs::write(&hello_txt, "#!/bin/sh\necho second\n").unwrap();
        let stale = app
            .cache_status(Some(&repo_root), "hello-tool", "*")
            .unwrap();
        assert_eq!(stale.status, "stale");
        assert_eq!(
            normalize_existing_path(stale.archive_path.as_ref().unwrap()),
            normalize_existing_path(&build.package_archive_path)
        );
        assert_ne!(stale.recipe_hash, ready.recipe_hash);

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn install_commit_failure_writes_failed_transaction_record() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("sloppkg-core-commit-fail-{unique}"));
        let state_root = root.join("state");
        let repo_root = root.join("repo");
        let packages_root = repo_root.join("packages");
        let target_root = root.join("target");

        fs::create_dir_all(&packages_root).unwrap();
        fs::write(
            repo_root.join("repo.toml"),
            "name = \"workspace\"\nkind = \"recipe\"\n",
        )
        .unwrap();

        write_test_package(
            &packages_root,
            "hello-tool",
            "0.1.0",
            1,
            r#"[package]
name = "hello-tool"
version = "0.1.0"
release = 1
summary = "hello tool"
description = "hello tool"
license = "MIT"
architectures = ["aarch64"]

[[sources]]
kind = "file"
url = "hello.txt"
sha256 = "local"
destination = "hello.txt"

[build]
system = "custom"
out_of_tree = true
install = [
  "mkdir -p \"$PKG_DESTDIR/usr/local/bin\"",
  "install -m 0755 \"$PKG_SOURCE_DIR/hello.txt\" \"$PKG_DESTDIR/usr/local/bin/hello-tool\""
]

[install]
prefix = "/usr/local"
owned_prefixes = ["/usr/local"]
"#,
            "#!/bin/sh\necho hello\n",
        );
        fs::write(
            packages_root.join("hello-tool/0.1.0-1").join("hello.txt"),
            "#!/bin/sh\necho hello\n",
        )
        .unwrap();

        fs::create_dir_all(&target_root).unwrap();
        fs::set_permissions(&target_root, fs::Permissions::from_mode(0o555)).unwrap();

        let app = App::new(AppPaths::from_state_root(state_root.clone()));
        let err = app
            .install(Some(&repo_root), "hello-tool", "*", &target_root)
            .unwrap_err();
        assert!(matches!(err, AppError::Io { .. }));

        let statuses = list_transaction_statuses(&app.paths.database_path).unwrap();
        assert_eq!(statuses.len(), 2);
        let latest = statuses
            .iter()
            .max_by_key(|status| status.transaction_id)
            .unwrap();
        assert_eq!(latest.status, "failed");

        let transaction_path = app
            .paths
            .transactions_dir
            .join(format!("{}.json", latest.transaction_id));
        let transaction = serde_json::from_str::<serde_json::Value>(
            &fs::read_to_string(&transaction_path).unwrap(),
        )
        .unwrap();
        assert_eq!(transaction["status"], "failed");
        assert_eq!(transaction["phase"], "commit");
        assert!(transaction["error"]
            .as_str()
            .unwrap()
            .contains("I/O failure"));

        fs::set_permissions(&target_root, fs::Permissions::from_mode(0o755)).unwrap();
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn install_marks_transaction_when_post_success_maintenance_fails() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "sloppkg-core-maintenance-transaction-fail-{unique}"
        ));
        let state_root = root.join("state");
        let repo_root = root.join("repo");
        let packages_root = repo_root.join("packages");
        let target_root = root.join("target");

        fs::create_dir_all(&packages_root).unwrap();
        fs::write(
            repo_root.join("repo.toml"),
            "name = \"workspace\"\nkind = \"recipe\"\n",
        )
        .unwrap();

        write_test_package(
            &packages_root,
            "hello-tool",
            "0.1.0",
            1,
            r#"[package]
name = "hello-tool"
version = "0.1.0"
release = 1
summary = "hello tool"
description = "hello tool"
license = "MIT"
architectures = ["aarch64"]

[[sources]]
kind = "file"
url = "hello.txt"
sha256 = "local"
destination = "hello.txt"

[build]
system = "custom"
out_of_tree = true
install = [
  "mkdir -p \"$PKG_DESTDIR/usr/local/bin\"",
  "install -m 0755 \"$PKG_SOURCE_DIR/hello.txt\" \"$PKG_DESTDIR/usr/local/bin/hello-tool\""
]

[install]
prefix = "/usr/local"
owned_prefixes = ["/usr/local"]
"#,
            "#!/bin/sh\necho hello\n",
        );
        fs::write(
            packages_root.join("hello-tool/0.1.0-1").join("hello.txt"),
            "#!/bin/sh\necho hello\n",
        )
        .unwrap();

        let app = App::new(AppPaths::from_state_root(state_root.clone()));
        app.write_publish_state(
            "workspace",
            &PublishState {
                repo_name: String::from("workspace"),
                source_root: root.join("missing-repo").display().to_string(),
                channel: String::from("stable"),
                keep_revisions: 1,
                remember: true,
            },
        )
        .unwrap();

        let err = app
            .install(Some(&repo_root), "hello-tool", "*", &target_root)
            .unwrap_err();
        let (transaction_id, transaction_path, reason) = match err {
            AppError::PostTransactionMaintenanceFailed {
                transaction_id,
                transaction_path,
                reason,
            } => (transaction_id, transaction_path, reason),
            other => panic!("unexpected error: {other:?}"),
        };
        assert!(reason.contains("missing-repo"));
        assert!(target_root.join("usr/local/bin/hello-tool").exists());

        let statuses = list_transaction_statuses(&app.paths.database_path).unwrap();
        let latest = statuses
            .iter()
            .max_by_key(|status| status.transaction_id)
            .unwrap();
        assert_eq!(latest.transaction_id, transaction_id);
        assert_eq!(latest.status, "maintenance-failed");

        let transaction = serde_json::from_str::<serde_json::Value>(
            &fs::read_to_string(&transaction_path).unwrap(),
        )
        .unwrap();
        assert_eq!(transaction["status"], "maintenance-failed");
        assert_eq!(transaction["maintenance"]["status"], "failed");
        assert!(transaction["maintenance"]["error"]
            .as_str()
            .unwrap()
            .contains("missing-repo"));
        assert_eq!(transaction["report"]["transaction_id"], transaction_id);

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn cleanup_builds_removes_terminal_transaction_dirs() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("sloppkg-core-cleanup-builds-{unique}"));
        let state_root = root.join("state");
        let app = App::new(AppPaths::from_state_root(state_root.clone()));
        app.init(None).unwrap();

        let completed_tx =
            create_transaction(&app.paths.database_path, "build", "{}", &[]).unwrap();
        update_transaction_status(&app.paths.database_path, completed_tx, "packaged").unwrap();
        let active_tx = create_transaction(&app.paths.database_path, "build", "{}", &[]).unwrap();
        update_transaction_status(&app.paths.database_path, active_tx, "building").unwrap();

        let completed_dir = app
            .paths
            .build_dir
            .join(format!("hello-0.1.0-1-tx{completed_tx}"));
        let active_dir = app
            .paths
            .build_dir
            .join(format!("hello-0.1.0-1-tx{active_tx}"));
        let scratch_dir = app.paths.build_dir.join("scratch-space");
        fs::create_dir_all(&completed_dir).unwrap();
        fs::create_dir_all(&active_dir).unwrap();
        fs::create_dir_all(&scratch_dir).unwrap();
        fs::write(completed_dir.join("artifact.txt"), "complete").unwrap();
        fs::write(active_dir.join("artifact.txt"), "active").unwrap();
        fs::write(scratch_dir.join("note.txt"), "keep").unwrap();

        let report = app.cleanup(CleanupTarget::Builds).unwrap();

        assert_eq!(report.total_removed, 1);
        assert_eq!(report.total_kept, 2);
        assert!(!completed_dir.exists());
        assert!(active_dir.exists());
        assert!(scratch_dir.exists());
        assert_eq!(
            report.scopes[0].removed[0].reason,
            format!("transaction {completed_tx} is packaged")
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn cleanup_repos_keeps_active_snapshot_and_prunes_stale_ones() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("sloppkg-core-cleanup-repos-{unique}"));
        let state_root = root.join("state");
        let app = App::new(AppPaths::from_state_root(state_root.clone()));
        app.init(None).unwrap();
        app.add_repo(RepoConfigEntry {
            name: String::from("main"),
            kind: RepoKind::Unified,
            url: String::from("http://127.0.0.1:18083"),
            channel: Some(String::from("stable")),
            priority: 50,
            enabled: true,
            trust_policy: RepoTrustMode::DigestPinned,
            sync_strategy: RepoSyncStrategy::StaticHttp,
        })
        .unwrap();

        let active_snapshot = app
            .paths
            .repo_snapshots_dir
            .join("main")
            .join("stable")
            .join("2026.03.26");
        let stale_snapshot = app
            .paths
            .repo_snapshots_dir
            .join("main")
            .join("stable")
            .join("2026.03.01");
        fs::create_dir_all(active_snapshot.join("packages/demo/0.1.0-1")).unwrap();
        fs::create_dir_all(stale_snapshot.join("packages/demo/0.0.9-1")).unwrap();
        fs::write(
            active_snapshot.join("packages/demo/0.1.0-1/package.toml"),
            "active",
        )
        .unwrap();
        fs::write(
            stale_snapshot.join("packages/demo/0.0.9-1/package.toml"),
            "stale",
        )
        .unwrap();
        fs::create_dir_all(app.paths.repo_state_dir.join("main")).unwrap();
        fs::write(
            app.paths.repo_state_dir.join("main/stable.toml"),
            format!(
                "format_version = 1\nrepo_name = \"main\"\nsource_url = \"http://127.0.0.1:18083\"\nchannel = \"stable\"\nrevision = \"2026.03.26\"\nsnapshot_root = \"{}\"\nupdated_at = 1\n",
                active_snapshot.display()
            ),
        )
        .unwrap();

        let report = app.cleanup(CleanupTarget::Repos).unwrap();

        assert_eq!(report.total_removed, 1);
        assert_eq!(report.total_kept, 1);
        assert!(active_snapshot.exists());
        assert!(!stale_snapshot.exists());
        assert_eq!(report.scopes[0].kept[0].reason, "active snapshot");

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn fetch_downloads_remote_distfiles_for_requested_package_and_build_deps() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("sloppkg-core-fetch-{unique}"));
        let state_root = root.join("state");
        let repo_root = root.join("repo");
        let packages_root = repo_root.join("packages");
        let remote_root = root.join("remote");

        fs::create_dir_all(&packages_root).unwrap();
        fs::create_dir_all(&remote_root).unwrap();
        fs::write(
            repo_root.join("repo.toml"),
            "name = \"workspace\"\nkind = \"recipe\"\n",
        )
        .unwrap();

        let dep_archive = remote_root.join("dep-lib-1.0.0.tar.gz");
        let app_archive = remote_root.join("app-1.0.0.tar.gz");
        fs::write(&dep_archive, b"dep-archive").unwrap();
        fs::write(&app_archive, b"app-archive").unwrap();
        let dep_sha = sha256_hex(&fs::read(&dep_archive).unwrap());
        let app_sha = sha256_hex(&fs::read(&app_archive).unwrap());

        let server = TestHttpServer::start(remote_root.clone(), 2);

        write_test_package(
            &packages_root,
            "dep-lib",
            "1.0.0",
            1,
            &format!(
                r#"[package]
name = "dep-lib"
version = "1.0.0"
release = 1
summary = "dep"
description = "dep"
license = "MIT"
architectures = ["aarch64"]

[[sources]]
kind = "archive"
url = "{}/dep-lib-1.0.0.tar.gz"
sha256 = "{dep_sha}"
strip_components = 1

[build]
system = "custom"
out_of_tree = true

[install]
prefix = "/usr/local"
owned_prefixes = ["/usr/local"]
"#,
                server.base_url(),
            ),
            "#!/bin/sh\nset -euo pipefail\n",
        );
        write_test_package(
            &packages_root,
            "app",
            "1.0.0",
            1,
            &format!(
                r#"[package]
name = "app"
version = "1.0.0"
release = 1
summary = "app"
description = "app"
license = "MIT"
architectures = ["aarch64"]

[[sources]]
kind = "archive"
url = "{}/app-1.0.0.tar.gz"
sha256 = "{app_sha}"
strip_components = 1

[build]
system = "custom"
out_of_tree = true

[install]
prefix = "/usr/local"
owned_prefixes = ["/usr/local"]

[[dependencies]]
name = "dep-lib"
constraint = ">= 1.0.0-1"
kind = "build"
"#,
                server.base_url(),
            ),
            "#!/bin/sh\nset -euo pipefail\n",
        );

        let app = App::new(AppPaths::from_state_root(state_root.clone()));
        let report = app.fetch(Some(&repo_root), "app", "*").unwrap();

        assert_eq!(report.packages.len(), 2);
        assert_eq!(report.downloaded, 2);
        assert!(state_root.join("distfiles/dep-lib-1.0.0.tar.gz").exists());
        assert!(state_root.join("distfiles/app-1.0.0.tar.gz").exists());

        server.join();
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn repo_publish_creates_live_revision_and_state() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("sloppkg-core-publish-{unique}"));
        let state_root = root.join("state");
        let repo_root = root.join("repo");
        let packages_root = repo_root.join("packages");

        fs::create_dir_all(&packages_root).unwrap();
        fs::write(
            repo_root.join("repo.toml"),
            "name = \"workspace\"\nkind = \"recipe\"\n",
        )
        .unwrap();
        write_test_package(
            &packages_root,
            "hello-tool",
            "0.1.0",
            1,
            r#"[package]
name = "hello-tool"
version = "0.1.0"
release = 1
summary = "hello tool"
description = "hello tool"
license = "MIT"
architectures = ["aarch64"]

[build]
system = "custom"
out_of_tree = true

[install]
prefix = "/usr/local"
owned_prefixes = ["/usr/local"]
"#,
            "#!/bin/sh\nset -euo pipefail\n",
        );

        let app = App::new(AppPaths::from_state_root(state_root.clone()));
        let report = app
            .publish_repo(
                Some(&repo_root),
                Some("workspace"),
                "stable",
                Some("rev-001"),
                1,
            )
            .unwrap();

        assert_eq!(report.repo_name, "workspace");
        assert!(report.published_root.join("repo.toml").exists());
        assert_eq!(
            normalize_existing_path(&report.live_root),
            normalize_existing_path(&report.published_root)
        );
        assert!(app
            .paths
            .published_repos_dir
            .join("workspace/publish.toml")
            .exists());

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn cleanup_published_keeps_live_and_previous_revision() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("sloppkg-core-cleanup-published-{unique}"));
        let state_root = root.join("state");
        let repo_root = root.join("repo");
        let packages_root = repo_root.join("packages");

        fs::create_dir_all(&packages_root).unwrap();
        fs::write(
            repo_root.join("repo.toml"),
            "name = \"workspace\"\nkind = \"recipe\"\n",
        )
        .unwrap();
        write_test_package(
            &packages_root,
            "hello-tool",
            "0.1.0",
            1,
            r#"[package]
name = "hello-tool"
version = "0.1.0"
release = 1
summary = "hello tool"
description = "hello tool"
license = "MIT"
architectures = ["aarch64"]

[build]
system = "custom"
out_of_tree = true

[install]
prefix = "/usr/local"
owned_prefixes = ["/usr/local"]
"#,
            "#!/bin/sh\nset -euo pipefail\n",
        );

        let app = App::new(AppPaths::from_state_root(state_root.clone()));
        app.publish_repo(
            Some(&repo_root),
            Some("workspace"),
            "stable",
            Some("rev-001"),
            1,
        )
        .unwrap();
        app.publish_repo(
            Some(&repo_root),
            Some("workspace"),
            "stable",
            Some("rev-002"),
            1,
        )
        .unwrap();
        app.publish_repo(
            Some(&repo_root),
            Some("workspace"),
            "stable",
            Some("rev-003"),
            1,
        )
        .unwrap();

        let report = app.cleanup(CleanupTarget::Published).unwrap();
        let revisions_root = app
            .paths
            .published_repos_dir
            .join("workspace/revisions/stable");
        assert!(!revisions_root.join("rev-001").exists());
        assert!(revisions_root.join("rev-002").exists());
        assert!(revisions_root.join("rev-003").exists());
        assert_eq!(report.total_removed, 1);
        assert_eq!(report.total_kept, 2);

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn install_auto_publishes_after_success_when_publish_state_exists() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("sloppkg-core-auto-publish-{unique}"));
        let state_root = root.join("state");
        let repo_root = root.join("repo");
        let packages_root = repo_root.join("packages");
        let target_root = root.join("target");

        fs::create_dir_all(&packages_root).unwrap();
        fs::write(
            repo_root.join("repo.toml"),
            "name = \"workspace\"\nkind = \"recipe\"\n",
        )
        .unwrap();
        write_test_package(
            &packages_root,
            "hello-tool",
            "0.1.0",
            1,
            r#"[package]
name = "hello-tool"
version = "0.1.0"
release = 1
summary = "hello tool"
description = "hello tool"
license = "MIT"
architectures = ["aarch64"]

[[sources]]
kind = "file"
url = "hello.txt"
sha256 = "local"
destination = "hello.txt"

[build]
system = "custom"
out_of_tree = true
install = [
  "mkdir -p \"$PKG_DESTDIR/usr/local/bin\"",
  "install -m 0755 \"$PKG_SOURCE_DIR/hello.txt\" \"$PKG_DESTDIR/usr/local/bin/hello-tool\""
]

[install]
prefix = "/usr/local"
owned_prefixes = ["/usr/local"]
"#,
            "#!/bin/sh\necho first\n",
        );
        fs::write(
            packages_root.join("hello-tool/0.1.0-1/hello.txt"),
            "#!/bin/sh\necho first\n",
        )
        .unwrap();

        let app = App::new(AppPaths::from_state_root(state_root.clone()));
        app.publish_repo(
            Some(&repo_root),
            Some("workspace"),
            "stable",
            Some("rev-001"),
            1,
        )
        .unwrap();
        let initial_live =
            normalize_existing_path(&app.paths.published_repos_dir.join("workspace/live"));

        fs::write(
            packages_root.join("hello-tool/0.1.0-1/hello.txt"),
            "#!/bin/sh\necho second\n",
        )
        .unwrap();
        app.install(Some(&repo_root), "hello-tool", "*", &target_root)
            .unwrap();

        let live_root = app.paths.published_repos_dir.join("workspace/live");
        let current_live = normalize_existing_path(&live_root);
        let revisions_root = app
            .paths
            .published_repos_dir
            .join("workspace/revisions/stable");
        let revision_count = fs::read_dir(&revisions_root).unwrap().count();

        assert_ne!(current_live, initial_live);
        assert_eq!(revision_count, 2);
        assert!(current_live.join("repo.toml").exists());
        assert!(current_live.join("recipes/index/stable.toml").exists());

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn non_remembered_publish_state_is_not_auto_republished() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root =
            std::env::temp_dir().join(format!("sloppkg-core-nonremember-publish-{unique}"));
        let state_root = root.join("state");
        let repo_root = root.join("repo");
        let packages_root = repo_root.join("packages");
        let target_root = root.join("target");

        fs::create_dir_all(&packages_root).unwrap();
        fs::write(
            repo_root.join("repo.toml"),
            "name = \"workspace-candidate\"\nkind = \"recipe\"\n",
        )
        .unwrap();
        write_test_package(
            &packages_root,
            "hello-tool",
            "0.1.0",
            1,
            r#"[package]
name = "hello-tool"
version = "0.1.0"
release = 1
summary = "hello tool"
description = "hello tool"
license = "MIT"
architectures = ["aarch64"]

[[sources]]
kind = "file"
url = "hello.txt"
sha256 = "local"
destination = "hello.txt"

[build]
system = "custom"
out_of_tree = true
install = [
  "mkdir -p \"$PKG_DESTDIR/usr/local/bin\"",
  "install -m 0755 \"$PKG_SOURCE_DIR/hello.txt\" \"$PKG_DESTDIR/usr/local/bin/hello-tool\""
]

[install]
prefix = "/usr/local"
owned_prefixes = ["/usr/local"]
"#,
            "#!/bin/sh\necho first\n",
        );
        fs::write(
            packages_root.join("hello-tool/0.1.0-1/hello.txt"),
            "#!/bin/sh\necho first\n",
        )
        .unwrap();

        let app = App::new(AppPaths::from_state_root(state_root.clone()));
        app.publish_repo_with_options(
            Some(&repo_root),
            Some("workspace-candidate"),
            "candidate",
            Some("cand-001"),
            1,
            RepoPublishOptions {
                remember_publish_state: false,
            },
        )
        .unwrap();
        let initial_live = normalize_existing_path(
            &app.paths.published_repos_dir.join("workspace-candidate/live"),
        );

        fs::write(
            packages_root.join("hello-tool/0.1.0-1/hello.txt"),
            "#!/bin/sh\necho second\n",
        )
        .unwrap();
        app.install(Some(&repo_root), "hello-tool", "*", &target_root)
            .unwrap();

        let live_root = app
            .paths
            .published_repos_dir
            .join("workspace-candidate/live");
        let current_live = normalize_existing_path(&live_root);
        let revisions_root = app
            .paths
            .published_repos_dir
            .join("workspace-candidate/revisions/candidate");
        let revision_count = fs::read_dir(&revisions_root).unwrap().count();
        let publish_state: toml::Value = toml::from_str(
            &fs::read_to_string(
                app.paths
                    .published_repos_dir
                    .join("workspace-candidate/publish.toml"),
            )
            .unwrap(),
        )
        .unwrap();

        assert_eq!(current_live, initial_live);
        assert_eq!(revision_count, 1);
        assert_eq!(publish_state["remember"].as_bool(), Some(false));

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn install_can_skip_publish_maintenance() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("sloppkg-core-skip-publish-{unique}"));
        let state_root = root.join("state");
        let repo_root = root.join("repo");
        let packages_root = repo_root.join("packages");
        let target_root = root.join("target");

        fs::create_dir_all(&packages_root).unwrap();
        fs::write(
            repo_root.join("repo.toml"),
            "name = \"workspace\"\nkind = \"recipe\"\n",
        )
        .unwrap();
        write_test_package(
            &packages_root,
            "hello-tool",
            "0.1.0",
            1,
            r#"[package]
name = "hello-tool"
version = "0.1.0"
release = 1
summary = "hello tool"
description = "hello tool"
license = "MIT"
architectures = ["aarch64"]

[[sources]]
kind = "file"
url = "hello.txt"
sha256 = "local"
destination = "hello.txt"

[build]
system = "custom"
out_of_tree = true
install = [
  "mkdir -p \"$PKG_DESTDIR/usr/local/bin\"",
  "install -m 0755 \"$PKG_SOURCE_DIR/hello.txt\" \"$PKG_DESTDIR/usr/local/bin/hello-tool\""
]

[install]
prefix = "/usr/local"
owned_prefixes = ["/usr/local"]
"#,
            "#!/bin/sh\necho first\n",
        );
        fs::write(
            packages_root.join("hello-tool/0.1.0-1/hello.txt"),
            "#!/bin/sh\necho first\n",
        )
        .unwrap();

        let app = App::new(AppPaths::from_state_root(state_root.clone()));
        app.write_publish_state(
            "workspace",
            &PublishState {
                repo_name: String::from("workspace"),
                source_root: root.join("missing-repo").display().to_string(),
                channel: String::from("stable"),
                keep_revisions: 1,
                remember: true,
            },
        )
        .unwrap();

        app
            .install_with_options(
                Some(&repo_root),
                "hello-tool",
                "*",
                &target_root,
                TransactionOptions {
                    skip_publish_maintenance: true,
                },
            )
            .unwrap();

        assert!(target_root.join("usr/local/bin/hello-tool").exists());

        let statuses = list_transaction_statuses(&app.paths.database_path).unwrap();
        let latest = statuses
            .iter()
            .max_by_key(|status| status.transaction_id)
            .unwrap();
        assert_eq!(latest.status, "complete");

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn promote_repo_copies_exact_candidate_revision() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("sloppkg-core-promote-repo-{unique}"));
        let state_root = root.join("state");
        let repo_root = root.join("repo");
        let packages_root = repo_root.join("packages");

        fs::create_dir_all(&packages_root).unwrap();
        fs::write(
            repo_root.join("repo.toml"),
            "name = \"workspace-candidate\"\nkind = \"recipe\"\n",
        )
        .unwrap();
        write_test_package(
            &packages_root,
            "hello-tool",
            "0.1.0",
            1,
            r#"[package]
name = "hello-tool"
version = "0.1.0"
release = 1
summary = "hello tool"
description = "hello tool"
license = "MIT"
architectures = ["aarch64"]

[build]
system = "custom"
out_of_tree = true

[install]
prefix = "/usr/local"
owned_prefixes = ["/usr/local"]
"#,
            "#!/bin/sh\nset -euo pipefail\n",
        );

        let app = App::new(AppPaths::from_state_root(state_root.clone()));
        let candidate = app
            .publish_repo_with_options(
                Some(&repo_root),
                Some("workspace-candidate"),
                "candidate",
                Some("cand-001"),
                2,
                RepoPublishOptions {
                    remember_publish_state: false,
                },
            )
            .unwrap();

        let report = app
            .promote_repo(
                "workspace-candidate",
                "candidate",
                Some("cand-001"),
                "workspace",
                "stable",
                2,
            )
            .unwrap();

        let stable_live = app.paths.published_repos_dir.join("workspace/live");
        let stable_publish: toml::Value = toml::from_str(
            &fs::read_to_string(app.paths.published_repos_dir.join("workspace/publish.toml"))
                .unwrap(),
        )
        .unwrap();

        assert_eq!(report.source_revision, "cand-001");
        assert_eq!(report.target_revision, "cand-001");
        assert!(report.target_published_root.join("repo.toml").exists());
        assert_eq!(
            fs::read_to_string(candidate.published_root.join("repo.toml")).unwrap(),
            fs::read_to_string(report.target_published_root.join("repo.toml")).unwrap()
        );
        assert_eq!(
            normalize_existing_path(&stable_live),
            normalize_existing_path(&report.target_published_root)
        );
        assert_eq!(stable_publish["remember"].as_bool(), Some(true));

        let _ = fs::remove_dir_all(root);
    }

    fn write_test_package(
        packages_root: &Path,
        name: &str,
        version: &str,
        release: u64,
        package_toml: &str,
        build_sh: &str,
    ) {
        let package_dir = packages_root
            .join(name)
            .join(format!("{version}-{release}"));
        fs::create_dir_all(&package_dir).unwrap();
        fs::write(package_dir.join("package.toml"), package_toml).unwrap();
        fs::write(package_dir.join("build.sh"), build_sh).unwrap();
    }

    fn sha256_hex(bytes: &[u8]) -> String {
        let mut hasher = Sha256::new();
        hasher.update(bytes);
        format!("{:x}", hasher.finalize())
    }

    struct TestHttpServer {
        join_handle: thread::JoinHandle<()>,
        address: String,
    }

    impl TestHttpServer {
        fn start(root: std::path::PathBuf, requests: usize) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let address = listener.local_addr().unwrap();
            let join_handle = thread::spawn(move || {
                for _ in 0..requests {
                    let (mut stream, _) = listener.accept().unwrap();
                    let mut request = [0_u8; 4096];
                    let read = stream.read(&mut request).unwrap();
                    let request_text = String::from_utf8_lossy(&request[..read]);
                    let path = request_text
                        .lines()
                        .next()
                        .and_then(|line| line.split_whitespace().nth(1))
                        .unwrap_or("/");
                    let relative = path.trim_start_matches('/');
                    let file_path = root.join(relative);
                    if file_path.exists() {
                        let body = fs::read(&file_path).unwrap();
                        write!(
                            stream,
                            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                            body.len()
                        )
                        .unwrap();
                        stream.write_all(&body).unwrap();
                    } else {
                        stream
                            .write_all(
                                b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                            )
                            .unwrap();
                    }
                }
            });
            Self {
                join_handle,
                address: format!("http://{}", address),
            }
        }

        fn base_url(&self) -> String {
            self.address.clone()
        }

        fn join(self) {
            self.join_handle.join().unwrap();
        }
    }
}
