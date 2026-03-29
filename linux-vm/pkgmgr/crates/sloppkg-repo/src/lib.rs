use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::fs::File;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sloppkg_types::{
    BinaryCapability, BinaryDependency, BinaryPackageInfo, BootstrapSpec, BootstrapStage,
    BuildSpec, Capability, Constraint, Dependency, DependencyGroup, DependencyKind, Evr,
    InstallSpec, PackageManifest, PackageMeta, PackageRecord, RecipeBundleManifest,
    RecipeSnapshotIndex, RepoConfigEntry, RepoKind, SourceSpec, UnifiedRepoMetadata,
};
use thiserror::Error;
use walkdir::WalkDir;

#[derive(Debug, Error)]
pub enum RepoError {
    #[error("failed to read repository metadata at {path}: {source}")]
    Read {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("failed to write repository metadata at {path}: {source}")]
    Write {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("failed to parse TOML at {path}: {source}")]
    Parse {
        path: PathBuf,
        #[source]
        source: toml::de::Error,
    },
    #[error("failed to serialize TOML for {path}: {source}")]
    Serialize {
        path: PathBuf,
        #[source]
        source: toml::ser::Error,
    },
    #[error("invalid version data in {path}: {source}")]
    Version {
        path: PathBuf,
        #[source]
        source: sloppkg_types::VersionParseError,
    },
    #[error("repository kind {found:?} is not supported at {path}")]
    UnsupportedRepoKind { path: PathBuf, found: RepoKind },
    #[error("failed to update repository index at {path}: {source}")]
    Sql {
        path: PathBuf,
        #[source]
        source: rusqlite::Error,
    },
    #[error("package archive does not contain pkg-info.toml: {0}")]
    MissingPackageInfo(PathBuf),
    #[error("package archive does not contain manifest.json: {0}")]
    MissingManifest(PathBuf),
    #[error("no cached package found for {package} matching {constraint}")]
    CachedPackageNotFound { package: String, constraint: String },
    #[error("failed to parse manifest JSON at {path}: {source}")]
    ManifestParse {
        path: PathBuf,
        #[source]
        source: serde_json::Error,
    },
    #[error("unsupported repository URL {url}: {reason}")]
    UnsupportedRepoUrl { url: String, reason: String },
    #[error("failed to connect to repository URL {url}: {source}")]
    HttpConnect {
        url: String,
        #[source]
        source: std::io::Error,
    },
    #[error("failed to read repository response from {url}: {source}")]
    HttpRead {
        url: String,
        #[source]
        source: std::io::Error,
    },
    #[error("invalid HTTP response from {url}: {reason}")]
    HttpProtocol { url: String, reason: String },
    #[error("repository URL {url} returned HTTP status {status}")]
    HttpStatus { url: String, status: String },
    #[error("unified repo {repo} does not define channel {channel}")]
    MissingRecipeChannel { repo: String, channel: String },
    #[error("digest mismatch for {path}: expected {expected}, got {actual}")]
    DigestMismatch {
        path: String,
        expected: String,
        actual: String,
    },
    #[error("unsafe relative path in repository metadata: {path}")]
    UnsafeRelativePath { path: String },
}

#[derive(Clone, Debug)]
pub struct RepoSnapshot {
    pub name: String,
    pub kind: RepoKind,
    pub priority: i32,
    pub root: PathBuf,
    pub packages: Vec<PackageRecord>,
}

#[derive(Clone, Debug, Serialize)]
pub struct BinaryRepoIndexReport {
    pub repo_root: PathBuf,
    pub repo_name: String,
    pub generated_at: u64,
    pub architectures: Vec<String>,
    pub package_count: usize,
    pub repo_toml_path: PathBuf,
    pub index_path: PathBuf,
}

#[derive(Clone, Debug, Serialize)]
pub struct CachedBinaryPackage {
    pub archive_path: PathBuf,
    pub archive_size: u64,
    pub archive_sha256: String,
    pub info: BinaryPackageInfo,
    pub manifest: PackageManifest,
}

#[derive(Clone, Debug, Serialize)]
pub struct UnifiedRepoSyncReport {
    pub repo_name: String,
    pub channel: String,
    pub revision: String,
    pub snapshot_root: PathBuf,
    pub package_count: usize,
    pub file_count: usize,
    pub changed: bool,
}

#[derive(Clone, Debug, Serialize)]
pub struct UnifiedRepoExportReport {
    pub repo_name: String,
    pub channel: String,
    pub revision: String,
    pub output_root: PathBuf,
    pub package_count: usize,
    pub version_count: usize,
    pub file_count: usize,
}

#[derive(Debug, Deserialize, Serialize)]
struct CachedUnifiedRepoState {
    format_version: u32,
    repo_name: String,
    source_url: String,
    channel: String,
    revision: String,
    snapshot_root: String,
    updated_at: u64,
}

pub fn load_recipe_repo(root: &Path, priority: i32) -> Result<RepoSnapshot, RepoError> {
    let repo_toml_path = root.join("repo.toml");
    let repo_toml = read_toml::<RawRepo>(&repo_toml_path)?;
    if repo_toml.kind != RepoKind::Recipe {
        return Err(RepoError::UnsupportedRepoKind {
            path: repo_toml_path,
            found: repo_toml.kind,
        });
    }

    let packages_root = if root.join("packages").is_dir() {
        root.join("packages")
    } else {
        root.to_path_buf()
    };
    let packages = WalkDir::new(&packages_root)
        .into_iter()
        .filter_map(Result::ok)
        .filter(|entry| entry.file_name() == "package.toml")
        .map(|entry| load_package_record(root, &repo_toml.name, priority, entry.path()))
        .collect::<Result<Vec<_>, _>>()?;

    Ok(RepoSnapshot {
        name: repo_toml.name,
        kind: repo_toml.kind,
        priority,
        root: root.to_path_buf(),
        packages,
    })
}

pub fn read_unified_repo_metadata(path: &Path) -> Result<UnifiedRepoMetadata, RepoError> {
    let metadata = read_toml::<UnifiedRepoMetadata>(path)?;
    if metadata.kind != RepoKind::Unified {
        return Err(RepoError::UnsupportedRepoKind {
            path: path.to_path_buf(),
            found: metadata.kind,
        });
    }
    Ok(metadata)
}

pub fn read_recipe_snapshot_index(path: &Path) -> Result<RecipeSnapshotIndex, RepoError> {
    read_toml(path)
}

pub fn read_recipe_bundle_manifest(path: &Path) -> Result<RecipeBundleManifest, RepoError> {
    read_toml(path)
}

pub fn sync_unified_repo(
    repo: &RepoConfigEntry,
    repo_state_dir: &Path,
    repo_snapshots_dir: &Path,
) -> Result<UnifiedRepoSyncReport, RepoError> {
    let parsed_url = ParsedHttpUrl::parse(&repo.url)?;
    let repo_toml_url = parsed_url.join("repo.toml")?;
    let repo_bytes = http_get_bytes(&repo_toml_url)?;
    let remote_metadata: UnifiedRepoMetadata = toml::from_str(
        std::str::from_utf8(&repo_bytes).map_err(|_| RepoError::HttpProtocol {
            url: repo_toml_url.clone(),
            reason: String::from("response body is not valid UTF-8"),
        })?,
    )
    .map_err(|source| RepoError::Parse {
        path: PathBuf::from("repo.toml"),
        source,
    })?;
    if remote_metadata.kind != RepoKind::Unified {
        return Err(RepoError::UnsupportedRepoKind {
            path: PathBuf::from("repo.toml"),
            found: remote_metadata.kind,
        });
    }

    let channel = repo
        .channel
        .clone()
        .unwrap_or_else(|| remote_metadata.default_channel.clone());
    let channel_meta = remote_metadata
        .recipes
        .channels
        .get(&channel)
        .ok_or_else(|| RepoError::MissingRecipeChannel {
            repo: remote_metadata.name.clone(),
            channel: channel.clone(),
        })?;
    let revision_component = safe_path_component(&channel_meta.current_revision)?;
    let repo_component = safe_path_component(&repo.name)?;
    let channel_component = safe_path_component(&channel)?;

    let previous_state =
        read_cached_unified_repo_state(repo_state_dir, &repo_component, &channel_component)?;

    let index_rel = sanitize_relative_path(&channel_meta.index_path)?;
    let index_url = parsed_url.join(relative_path_string(&index_rel).as_str())?;
    let index_bytes = http_get_bytes(&index_url)?;
    verify_digest(
        &channel_meta.index_path,
        &channel_meta.index_sha256,
        &index_bytes,
    )?;
    let index: RecipeSnapshotIndex = toml::from_str(std::str::from_utf8(&index_bytes).map_err(
        |_| RepoError::HttpProtocol {
            url: index_url.clone(),
            reason: String::from("response body is not valid UTF-8"),
        },
    )?)
    .map_err(|source| RepoError::Parse {
        path: PathBuf::from(&channel_meta.index_path),
        source,
    })?;

    let snapshot_root = repo_snapshots_dir
        .join(&repo_component)
        .join(&channel_component)
        .join(&revision_component);
    let snapshot_parent = snapshot_root
        .parent()
        .map(Path::to_path_buf)
        .ok_or_else(|| RepoError::UnsafeRelativePath {
            path: snapshot_root.display().to_string(),
        })?;
    fs::create_dir_all(&snapshot_parent).map_err(|source| RepoError::Write {
        path: snapshot_parent.clone(),
        source,
    })?;

    let temp_root = snapshot_parent.join(format!(
        ".tmp-{}-{}",
        revision_component,
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    ));
    if temp_root.exists() {
        fs::remove_dir_all(&temp_root).map_err(|source| RepoError::Write {
            path: temp_root.clone(),
            source,
        })?;
    }
    fs::create_dir_all(temp_root.join("packages")).map_err(|source| RepoError::Write {
        path: temp_root.join("packages"),
        source,
    })?;

    write_toml(
        &temp_root.join("repo.toml"),
        &LocalRecipeRepoMetadata {
            name: remote_metadata.name.clone(),
            kind: RepoKind::Recipe,
        },
    )?;
    write_bytes(&temp_root.join("remote-repo.toml"), &repo_bytes)?;
    write_bytes(&temp_root.join("recipe-index.toml"), &index_bytes)?;

    let mut file_count = 0usize;
    for package in &index.recipes {
        for version in &package.versions {
            let manifest_rel = sanitize_relative_path(&version.manifest_path)?;
            let manifest_url = parsed_url.join(relative_path_string(&manifest_rel).as_str())?;
            let manifest_bytes = http_get_bytes(&manifest_url)?;
            verify_digest(
                &version.manifest_path,
                &version.manifest_sha256,
                &manifest_bytes,
            )?;
            let manifest: RecipeBundleManifest =
                toml::from_str(std::str::from_utf8(&manifest_bytes).map_err(|_| {
                    RepoError::HttpProtocol {
                        url: manifest_url.clone(),
                        reason: String::from("response body is not valid UTF-8"),
                    }
                })?)
                .map_err(|source| RepoError::Parse {
                    path: PathBuf::from(&version.manifest_path),
                    source,
                })?;

            let package_dir = local_snapshot_package_dir(&temp_root, &manifest)?;
            fs::create_dir_all(&package_dir).map_err(|source| RepoError::Write {
                path: package_dir.clone(),
                source,
            })?;
            write_bytes(&package_dir.join(".sloppkg-manifest.toml"), &manifest_bytes)?;

            let manifest_parent = manifest_rel.parent().unwrap_or_else(|| Path::new(""));
            for file in &manifest.files {
                let file_rel = sanitize_relative_path(&file.path)?;
                let remote_rel = manifest_parent.join(&file_rel);
                let remote_rel_string = relative_path_string(&remote_rel);
                let file_url = parsed_url.join(remote_rel_string.as_str())?;
                let file_bytes = http_get_bytes(&file_url)?;
                verify_digest(&remote_rel_string, &file.sha256, &file_bytes)?;
                let target_path = package_dir.join(&file_rel);
                if let Some(parent) = target_path.parent() {
                    fs::create_dir_all(parent).map_err(|source| RepoError::Write {
                        path: parent.to_path_buf(),
                        source,
                    })?;
                }
                write_bytes(&target_path, &file_bytes)?;
                file_count += 1;
            }
        }
    }

    if snapshot_root.exists() {
        fs::remove_dir_all(&snapshot_root).map_err(|source| RepoError::Write {
            path: snapshot_root.clone(),
            source,
        })?;
    }
    fs::rename(&temp_root, &snapshot_root).map_err(|source| RepoError::Write {
        path: snapshot_root.clone(),
        source,
    })?;

    let updated_at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    write_cached_unified_repo_state(
        repo_state_dir,
        &repo_component,
        &channel_component,
        &CachedUnifiedRepoState {
            format_version: 1,
            repo_name: remote_metadata.name.clone(),
            source_url: repo.url.clone(),
            channel: channel.clone(),
            revision: channel_meta.current_revision.clone(),
            snapshot_root: snapshot_root.to_string_lossy().into_owned(),
            updated_at,
        },
    )?;
    if repo.channel.is_none() {
        write_toml(
            &repo_state_dir.join(&repo_component).join("default.toml"),
            &CachedUnifiedRepoState {
                format_version: 1,
                repo_name: remote_metadata.name.clone(),
                source_url: repo.url.clone(),
                channel: channel.clone(),
                revision: channel_meta.current_revision.clone(),
                snapshot_root: snapshot_root.to_string_lossy().into_owned(),
                updated_at,
            },
        )?;
    }

    Ok(UnifiedRepoSyncReport {
        repo_name: repo.name.clone(),
        channel,
        revision: channel_meta.current_revision.clone(),
        snapshot_root: snapshot_root.clone(),
        package_count: index
            .recipes
            .iter()
            .map(|package| package.versions.len())
            .sum(),
        file_count,
        changed: previous_state
            .map(|state| state.revision != channel_meta.current_revision)
            .unwrap_or(true),
    })
}

pub fn cached_unified_snapshot_root(
    repo: &RepoConfigEntry,
    repo_state_dir: &Path,
) -> Result<Option<PathBuf>, RepoError> {
    let repo_component = safe_path_component(&repo.name)?;
    let state = if let Some(channel) = &repo.channel {
        let channel_component = safe_path_component(channel)?;
        read_cached_unified_repo_state(repo_state_dir, &repo_component, &channel_component)?
    } else {
        let path = repo_state_dir.join(&repo_component).join("default.toml");
        if path.exists() {
            Some(read_toml(&path)?)
        } else {
            None
        }
    };
    let Some(state) = state else {
        return Ok(None);
    };
    Ok(Some(PathBuf::from(state.snapshot_root)))
}

pub fn export_unified_recipe_repo(
    recipe_root: &Path,
    output_root: &Path,
    channel: &str,
    revision: Option<&str>,
) -> Result<UnifiedRepoExportReport, RepoError> {
    let snapshot = load_recipe_repo(recipe_root, 50)?;
    let repo_name = snapshot.name.clone();
    let channel_name = channel.to_owned();
    let revision_name = revision
        .map(str::to_owned)
        .unwrap_or_else(default_revision_string);
    let generated_at = current_timestamp_string();
    let channel_component = safe_path_component(&channel_name)?;
    let revision_component = safe_path_component(&revision_name)?;

    if output_root.exists() {
        fs::remove_dir_all(output_root).map_err(|source| RepoError::Write {
            path: output_root.to_path_buf(),
            source,
        })?;
    }
    fs::create_dir_all(output_root).map_err(|source| RepoError::Write {
        path: output_root.to_path_buf(),
        source,
    })?;

    let mut packages_by_name = BTreeMap::<String, Vec<&PackageRecord>>::new();
    let mut file_count = 0usize;
    let mut version_count = 0usize;

    for package in &snapshot.packages {
        packages_by_name
            .entry(package.package.name.clone())
            .or_default()
            .push(package);
    }

    let mut recipe_index_packages = Vec::new();
    for (package_name, versions) in &packages_by_name {
        let mut sorted_versions = versions.clone();
        sorted_versions.sort_by(|left, right| right.package.evr.cmp(&left.package.evr));

        let mut index_versions = Vec::new();
        for package in sorted_versions {
            let recipe_dir =
                package
                    .recipe_path
                    .parent()
                    .ok_or_else(|| RepoError::UnsafeRelativePath {
                        path: package.recipe_path.display().to_string(),
                    })?;
            let bundle_relative = PathBuf::from("recipes")
                .join("by-name")
                .join(safe_path_component(&package.package.name)?)
                .join(safe_path_component(&package.package.evr.to_string())?);
            let bundle_root = output_root.join(&bundle_relative);
            fs::create_dir_all(&bundle_root).map_err(|source| RepoError::Write {
                path: bundle_root.clone(),
                source,
            })?;

            let mut bundle_files = Vec::new();
            for entry in WalkDir::new(recipe_dir).into_iter().filter_map(Result::ok) {
                let path = entry.path();
                let relative =
                    path.strip_prefix(recipe_dir)
                        .map_err(|_| RepoError::UnsafeRelativePath {
                            path: path.display().to_string(),
                        })?;
                if relative.as_os_str().is_empty() || path.is_dir() {
                    continue;
                }
                let relative_string = relative_path_string(relative);
                let target = bundle_root.join(relative);
                copy_repo_file(path, &target)?;
                let bytes = fs::read(path).map_err(|source| RepoError::Read {
                    path: path.to_path_buf(),
                    source,
                })?;
                bundle_files.push(sloppkg_types::RecipeBundleFile {
                    path: relative_string,
                    sha256: hash_bytes(&bytes),
                });
                file_count += 1;
            }
            bundle_files.sort_by(|left, right| left.path.cmp(&right.path));

            let manifest = RecipeBundleManifest {
                format_version: 1,
                package_name: package.package.name.clone(),
                epoch: package.package.evr.epoch,
                version: package.package.evr.version.clone(),
                release: package.package.evr.release.clone(),
                files: bundle_files,
            };
            let manifest_relative = bundle_relative.join("manifest.toml");
            let manifest_path = output_root.join(&manifest_relative);
            let manifest_toml =
                toml::to_string_pretty(&manifest).map_err(|source| RepoError::Serialize {
                    path: manifest_path.clone(),
                    source,
                })?;
            fs::write(&manifest_path, &manifest_toml).map_err(|source| RepoError::Write {
                path: manifest_path.clone(),
                source,
            })?;

            index_versions.push(sloppkg_types::RecipeIndexVersion {
                epoch: package.package.evr.epoch,
                version: package.package.evr.version.clone(),
                release: package.package.evr.release.clone(),
                manifest_path: relative_path_string(&manifest_relative),
                manifest_sha256: hash_bytes(manifest_toml.as_bytes()),
            });
            version_count += 1;
        }

        recipe_index_packages.push(sloppkg_types::RecipeIndexPackage {
            name: package_name.clone(),
            versions: index_versions,
        });
    }

    let index_relative = PathBuf::from("recipes")
        .join("index")
        .join(format!("{channel_component}.toml"));
    let index_path = output_root.join(&index_relative);
    let index = RecipeSnapshotIndex {
        format_version: 1,
        repo_name: repo_name.clone(),
        channel: channel_name.clone(),
        revision: revision_name.clone(),
        generated_at: generated_at.clone(),
        recipes: recipe_index_packages,
    };
    let index_toml = toml::to_string_pretty(&index).map_err(|source| RepoError::Serialize {
        path: index_path.clone(),
        source,
    })?;
    fs::create_dir_all(index_path.parent().unwrap_or(output_root)).map_err(|source| {
        RepoError::Write {
            path: index_path.parent().unwrap_or(output_root).to_path_buf(),
            source,
        }
    })?;
    fs::write(&index_path, &index_toml).map_err(|source| RepoError::Write {
        path: index_path.clone(),
        source,
    })?;

    let repo_metadata = UnifiedRepoMetadata {
        format_version: 1,
        name: repo_name.clone(),
        kind: RepoKind::Unified,
        generated_at,
        default_channel: channel_name.clone(),
        capabilities: vec![sloppkg_types::RepoCapability::Recipes],
        recipes: sloppkg_types::UnifiedRecipeCollection {
            channels: BTreeMap::from([(
                channel_name.clone(),
                sloppkg_types::RecipeChannelMetadata {
                    current_revision: revision_name.clone(),
                    index_path: relative_path_string(&index_relative),
                    index_sha256: hash_bytes(index_toml.as_bytes()),
                    compression: String::from("zst"),
                },
            )]),
        },
        binaries: BTreeMap::new(),
        trust: sloppkg_types::UnifiedRepoTrust {
            mode: sloppkg_types::RepoTrustMode::DigestPinned,
            signatures: String::from("none"),
        },
    };
    write_toml(&output_root.join("repo.toml"), &repo_metadata)?;

    Ok(UnifiedRepoExportReport {
        repo_name,
        channel: channel_name,
        revision: revision_component,
        output_root: output_root.to_path_buf(),
        package_count: packages_by_name.len(),
        version_count,
        file_count,
    })
}

pub fn generate_binary_repo_index(
    root: &Path,
    repo_name_override: Option<&str>,
) -> Result<BinaryRepoIndexReport, RepoError> {
    fs::create_dir_all(root).map_err(|source| RepoError::Write {
        path: root.to_path_buf(),
        source,
    })?;

    let packages = discover_binary_packages(root)?;
    let generated_at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let repo_name = repo_name_override
        .map(str::to_owned)
        .or(read_existing_binary_repo_name(root)?)
        .unwrap_or_else(|| String::from("local-cache"));
    let architectures = packages
        .iter()
        .map(|package| package.info.arch.clone())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect::<Vec<_>>();

    let repo_toml_path = root.join("repo.toml");
    let repodata_dir = root.join("repodata");
    let sqlite_path = repodata_dir.join("index.sqlite");
    let compressed_path = repodata_dir.join("index.sqlite.zst");

    fs::create_dir_all(&repodata_dir).map_err(|source| RepoError::Write {
        path: repodata_dir.clone(),
        source,
    })?;
    if sqlite_path.exists() {
        fs::remove_file(&sqlite_path).map_err(|source| RepoError::Write {
            path: sqlite_path.clone(),
            source,
        })?;
    }
    if compressed_path.exists() {
        fs::remove_file(&compressed_path).map_err(|source| RepoError::Write {
            path: compressed_path.clone(),
            source,
        })?;
    }

    write_binary_repo_metadata(
        &repo_toml_path,
        &BinaryRepoMetadata {
            format_version: 1,
            name: repo_name.clone(),
            kind: RepoKind::Binary,
            generated_at,
            architectures: architectures.clone(),
            compression: String::from("zst"),
            signature_type: String::from("none"),
        },
    )?;
    write_binary_repo_sqlite(
        &sqlite_path,
        &repo_name,
        generated_at,
        &architectures,
        &packages,
    )?;
    compress_file(&sqlite_path, &compressed_path)?;
    fs::remove_file(&sqlite_path).map_err(|source| RepoError::Write {
        path: sqlite_path,
        source,
    })?;

    Ok(BinaryRepoIndexReport {
        repo_root: root.to_path_buf(),
        repo_name,
        generated_at,
        architectures,
        package_count: packages.len(),
        repo_toml_path,
        index_path: compressed_path,
    })
}

pub fn find_cached_binary_package(
    root: &Path,
    package_name: &str,
    constraint: &Constraint,
) -> Result<CachedBinaryPackage, RepoError> {
    let packages = discover_binary_packages(root)?;
    let selected = packages
        .into_iter()
        .filter(|package| package.info.package_name == package_name)
        .filter(|package| {
            constraint.matches(&Evr::new(
                package.info.epoch,
                package.info.version.clone(),
                package.info.release.clone(),
            ))
        })
        .max_by(|left, right| {
            Evr::new(
                left.info.epoch,
                left.info.version.clone(),
                left.info.release.clone(),
            )
            .cmp(&Evr::new(
                right.info.epoch,
                right.info.version.clone(),
                right.info.release.clone(),
            ))
        })
        .ok_or_else(|| RepoError::CachedPackageNotFound {
            package: package_name.to_owned(),
            constraint: constraint.to_string(),
        })?;

    let archive_path = root.join(&selected.archive_path);
    let (info, manifest) = read_binary_package_metadata(&archive_path)?;
    Ok(CachedBinaryPackage {
        archive_path,
        archive_size: selected.archive_size,
        archive_sha256: selected.archive_sha256,
        info,
        manifest,
    })
}

pub fn extract_binary_package(archive_path: &Path, destination: &Path) -> Result<(), RepoError> {
    fs::create_dir_all(destination).map_err(|source| RepoError::Write {
        path: destination.to_path_buf(),
        source,
    })?;
    let file = File::open(archive_path).map_err(|source| RepoError::Read {
        path: archive_path.to_path_buf(),
        source,
    })?;
    let decoder = zstd::Decoder::new(file).map_err(|source| RepoError::Read {
        path: archive_path.to_path_buf(),
        source,
    })?;
    let mut archive = tar::Archive::new(decoder);
    archive
        .unpack(destination)
        .map_err(|source| RepoError::Read {
            path: archive_path.to_path_buf(),
            source,
        })?;
    Ok(())
}

fn load_package_record(
    repo_root: &Path,
    repo_name: &str,
    priority: i32,
    package_path: &Path,
) -> Result<PackageRecord, RepoError> {
    let raw = read_toml::<RawPackageFile>(package_path)?;
    let package = PackageMeta {
        name: raw.package.name,
        evr: Evr::new(
            raw.package.epoch.unwrap_or(0),
            raw.package.version,
            raw.package.release,
        ),
        summary: raw.package.summary,
        description: raw.package.description,
        license: raw.package.license,
        homepage: raw.package.homepage,
        architectures: raw.package.architectures,
    };

    let dependencies = raw
        .dependencies
        .into_iter()
        .map(raw_dependency_to_dependency)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|source| RepoError::Version {
            path: package_path.to_path_buf(),
            source,
        })?;

    let dependency_groups = raw
        .dependency_groups
        .into_iter()
        .map(|group| {
            let one_of = group
                .one_of
                .into_iter()
                .map(raw_dependency_to_dependency)
                .collect::<Result<Vec<_>, _>>()?;
            Ok(DependencyGroup {
                kind: group.kind,
                one_of,
            })
        })
        .collect::<Result<Vec<_>, sloppkg_types::VersionParseError>>()
        .map_err(|source| RepoError::Version {
            path: package_path.to_path_buf(),
            source,
        })?;

    let provides = raw
        .provides
        .into_iter()
        .map(raw_capability_to_capability)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|source| RepoError::Version {
            path: package_path.to_path_buf(),
            source,
        })?;
    let conflicts = raw
        .conflicts
        .into_iter()
        .map(raw_capability_to_capability)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|source| RepoError::Version {
            path: package_path.to_path_buf(),
            source,
        })?;
    let replaces = raw
        .replaces
        .into_iter()
        .map(raw_capability_to_capability)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|source| RepoError::Version {
            path: package_path.to_path_buf(),
            source,
        })?;

    Ok(PackageRecord {
        repo_name: repo_name.to_owned(),
        repo_priority: priority,
        recipe_path: package_path.to_path_buf(),
        source_path: package_path
            .strip_prefix(repo_root)
            .unwrap_or(package_path)
            .to_path_buf(),
        package,
        sources: raw
            .sources
            .into_iter()
            .map(|source| SourceSpec {
                kind: source.kind,
                url: source.url,
                sha256: source.sha256,
                filename: source.filename,
                strip_components: source.strip_components.unwrap_or(1),
                destination: source.destination,
            })
            .collect(),
        build: BuildSpec {
            system: raw.build.system,
            out_of_tree: raw.build.out_of_tree.unwrap_or(true),
            directory: raw.build.directory,
            env: raw.build.env.unwrap_or_default().into_iter().collect(),
            configure: raw.build.configure,
            build: raw.build.build,
            install: raw.build.install,
            jobs: raw.build.jobs.unwrap_or(0),
        },
        install: InstallSpec {
            prefix: raw.install.prefix,
            sysconfdir: raw
                .install
                .sysconfdir
                .unwrap_or_else(|| String::from("/usr/local/etc")),
            localstatedir: raw
                .install
                .localstatedir
                .unwrap_or_else(|| String::from("/usr/local/var")),
            owned_prefixes: raw.install.owned_prefixes,
            strip_binaries: raw.install.strip_binaries.unwrap_or(false),
        },
        dependencies,
        dependency_groups,
        provides,
        conflicts,
        replaces,
        bootstrap: raw.bootstrap.map(|bootstrap| BootstrapSpec {
            sysroot: bootstrap.sysroot,
            stages: bootstrap
                .stages
                .into_iter()
                .map(|stage| BootstrapStage {
                    name: stage.name,
                    packages: stage.packages,
                    depends_on: stage.depends_on,
                    env: stage.env.unwrap_or_default().into_iter().collect(),
                })
                .collect(),
        }),
    })
}

fn discover_binary_packages(root: &Path) -> Result<Vec<IndexedBinaryPackage>, RepoError> {
    let mut packages = WalkDir::new(root)
        .into_iter()
        .filter_map(Result::ok)
        .filter(|entry| entry.file_type().is_file())
        .filter(|entry| {
            entry
                .path()
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.ends_with(".sloppkg.tar.zst"))
        })
        .filter(|entry| {
            !entry
                .path()
                .components()
                .any(|component| component.as_os_str() == "repodata")
        })
        .map(|entry| load_binary_package(root, entry.path()))
        .collect::<Result<Vec<_>, _>>()?;

    packages.sort_by(|left, right| {
        left.info
            .package_name
            .cmp(&right.info.package_name)
            .then_with(|| left.info.epoch.cmp(&right.info.epoch))
            .then_with(|| left.info.version.cmp(&right.info.version))
            .then_with(|| left.info.release.cmp(&right.info.release))
            .then_with(|| left.info.arch.cmp(&right.info.arch))
    });
    Ok(packages)
}

fn load_binary_package(
    root: &Path,
    archive_path: &Path,
) -> Result<IndexedBinaryPackage, RepoError> {
    let (info, _) = read_binary_package_metadata(archive_path)?;
    let archive_size = fs::metadata(archive_path)
        .map_err(|source| RepoError::Read {
            path: archive_path.to_path_buf(),
            source,
        })?
        .len();
    let archive_sha256 = hash_file(archive_path)?;
    let archive_path = archive_path
        .strip_prefix(root)
        .unwrap_or(archive_path)
        .to_string_lossy()
        .into_owned();

    Ok(IndexedBinaryPackage {
        info,
        archive_path,
        archive_size,
        archive_sha256,
    })
}

fn read_binary_package_metadata(
    archive_path: &Path,
) -> Result<(BinaryPackageInfo, PackageManifest), RepoError> {
    let file = File::open(archive_path).map_err(|source| RepoError::Read {
        path: archive_path.to_path_buf(),
        source,
    })?;
    let decoder = zstd::Decoder::new(file).map_err(|source| RepoError::Read {
        path: archive_path.to_path_buf(),
        source,
    })?;
    let mut archive = tar::Archive::new(decoder);
    let mut entries = archive.entries().map_err(|source| RepoError::Read {
        path: archive_path.to_path_buf(),
        source,
    })?;

    let mut package_info = None;
    let mut manifest = None;
    while let Some(entry) = entries.next() {
        let mut entry = entry.map_err(|source| RepoError::Read {
            path: archive_path.to_path_buf(),
            source,
        })?;
        let path = entry.path().map_err(|source| RepoError::Read {
            path: archive_path.to_path_buf(),
            source,
        })?;
        if path == Path::new("pkg-info.toml") {
            let mut contents = String::new();
            entry
                .read_to_string(&mut contents)
                .map_err(|source| RepoError::Read {
                    path: archive_path.to_path_buf(),
                    source,
                })?;
            package_info = Some(
                toml::from_str(&contents).map_err(|source| RepoError::Parse {
                    path: archive_path.to_path_buf(),
                    source,
                })?,
            );
        } else if path == Path::new("manifest.json") {
            let mut contents = String::new();
            entry
                .read_to_string(&mut contents)
                .map_err(|source| RepoError::Read {
                    path: archive_path.to_path_buf(),
                    source,
                })?;
            manifest = Some(serde_json::from_str(&contents).map_err(|source| {
                RepoError::ManifestParse {
                    path: archive_path.to_path_buf(),
                    source,
                }
            })?);
        }
    }

    let package_info =
        package_info.ok_or_else(|| RepoError::MissingPackageInfo(archive_path.to_path_buf()))?;
    let manifest =
        manifest.ok_or_else(|| RepoError::MissingManifest(archive_path.to_path_buf()))?;
    Ok((package_info, manifest))
}

fn write_binary_repo_metadata(path: &Path, metadata: &BinaryRepoMetadata) -> Result<(), RepoError> {
    let contents = toml::to_string_pretty(metadata).map_err(|source| RepoError::Serialize {
        path: path.to_path_buf(),
        source,
    })?;
    fs::write(path, contents).map_err(|source| RepoError::Write {
        path: path.to_path_buf(),
        source,
    })
}

fn write_binary_repo_sqlite(
    path: &Path,
    repo_name: &str,
    generated_at: u64,
    architectures: &[String],
    packages: &[IndexedBinaryPackage],
) -> Result<(), RepoError> {
    let connection = Connection::open(path).map_err(|source| RepoError::Sql {
        path: path.to_path_buf(),
        source,
    })?;
    connection
        .execute_batch(
            r#"
        PRAGMA journal_mode = DELETE;
        CREATE TABLE repo_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE packages (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            epoch INTEGER NOT NULL,
            version TEXT NOT NULL,
            release TEXT NOT NULL,
            arch TEXT NOT NULL,
            repo_name TEXT NOT NULL,
            source_path TEXT NOT NULL,
            summary TEXT NOT NULL,
            description TEXT NOT NULL,
            license TEXT NOT NULL,
            homepage TEXT,
            archive_path TEXT NOT NULL,
            archive_size INTEGER NOT NULL,
            archive_sha256 TEXT NOT NULL
        );
        CREATE UNIQUE INDEX idx_packages_identity
            ON packages(name, epoch, version, release, arch);
        CREATE TABLE dependencies (
            id INTEGER PRIMARY KEY,
            package_id INTEGER NOT NULL,
            dependency_name TEXT NOT NULL,
            constraint_text TEXT NOT NULL,
            kind TEXT NOT NULL,
            reason TEXT,
            feature TEXT,
            FOREIGN KEY(package_id) REFERENCES packages(id)
        );
        CREATE TABLE dependency_group_members (
            id INTEGER PRIMARY KEY,
            package_id INTEGER NOT NULL,
            group_index INTEGER NOT NULL,
            member_index INTEGER NOT NULL,
            dependency_name TEXT NOT NULL,
            constraint_text TEXT NOT NULL,
            kind TEXT NOT NULL,
            reason TEXT,
            feature TEXT,
            FOREIGN KEY(package_id) REFERENCES packages(id)
        );
        CREATE TABLE provides (
            id INTEGER PRIMARY KEY,
            package_id INTEGER NOT NULL,
            capability_name TEXT NOT NULL,
            constraint_text TEXT NOT NULL,
            FOREIGN KEY(package_id) REFERENCES packages(id)
        );
        CREATE TABLE conflicts (
            id INTEGER PRIMARY KEY,
            package_id INTEGER NOT NULL,
            capability_name TEXT NOT NULL,
            constraint_text TEXT NOT NULL,
            FOREIGN KEY(package_id) REFERENCES packages(id)
        );
        CREATE TABLE replaces (
            id INTEGER PRIMARY KEY,
            package_id INTEGER NOT NULL,
            capability_name TEXT NOT NULL,
            constraint_text TEXT NOT NULL,
            FOREIGN KEY(package_id) REFERENCES packages(id)
        );
        "#,
        )
        .map_err(|source| RepoError::Sql {
            path: path.to_path_buf(),
            source,
        })?;

    let metadata = BTreeMap::from([
        (String::from("format_version"), String::from("1")),
        (String::from("name"), repo_name.to_owned()),
        (String::from("kind"), String::from("binary")),
        (String::from("generated_at"), generated_at.to_string()),
        (String::from("architectures"), architectures.join(",")),
        (String::from("compression"), String::from("zst")),
        (String::from("signature_type"), String::from("none")),
        (String::from("package_count"), packages.len().to_string()),
    ]);
    for (key, value) in metadata {
        connection
            .execute(
                "INSERT INTO repo_metadata(key, value) VALUES(?1, ?2)",
                params![key, value],
            )
            .map_err(|source| RepoError::Sql {
                path: path.to_path_buf(),
                source,
            })?;
    }

    for package in packages {
        connection
            .execute(
                "INSERT INTO packages(name, epoch, version, release, arch, repo_name, source_path, summary, description, license, homepage, archive_path, archive_size, archive_sha256) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)",
                params![
                    package.info.package_name,
                    package.info.epoch,
                    package.info.version,
                    package.info.release,
                    package.info.arch,
                    package.info.repo_name,
                    package.info.source_path,
                    package.info.summary,
                    package.info.description,
                    package.info.license,
                    package.info.homepage,
                    package.archive_path,
                    package.archive_size as i64,
                    package.archive_sha256,
                ],
            )
            .map_err(|source| RepoError::Sql {
                path: path.to_path_buf(),
                source,
            })?;
        let package_id = connection.last_insert_rowid();

        for dependency in &package.info.dependencies {
            insert_dependency(&connection, path, package_id, dependency)?;
        }
        for (group_index, group) in package.info.dependency_groups.iter().enumerate() {
            for (member_index, dependency) in group.one_of.iter().enumerate() {
                connection
                    .execute(
                        "INSERT INTO dependency_group_members(package_id, group_index, member_index, dependency_name, constraint_text, kind, reason, feature) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                        params![
                            package_id,
                            group_index as i64,
                            member_index as i64,
                            dependency.name,
                            dependency.constraint,
                            dependency_kind_text(group.kind),
                            dependency.reason,
                            dependency.feature,
                        ],
                    )
                    .map_err(|source| RepoError::Sql {
                        path: path.to_path_buf(),
                        source,
                    })?;
            }
        }
        insert_capabilities(
            &connection,
            path,
            "provides",
            package_id,
            &package.info.provides,
        )?;
        insert_capabilities(
            &connection,
            path,
            "conflicts",
            package_id,
            &package.info.conflicts,
        )?;
        insert_capabilities(
            &connection,
            path,
            "replaces",
            package_id,
            &package.info.replaces,
        )?;
    }

    Ok(())
}

fn insert_dependency(
    connection: &Connection,
    path: &Path,
    package_id: i64,
    dependency: &BinaryDependency,
) -> Result<(), RepoError> {
    connection
        .execute(
            "INSERT INTO dependencies(package_id, dependency_name, constraint_text, kind, reason, feature) VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                package_id,
                dependency.name,
                dependency.constraint,
                dependency_kind_text(dependency.kind),
                dependency.reason,
                dependency.feature,
            ],
        )
        .map_err(|source| RepoError::Sql {
            path: path.to_path_buf(),
            source,
        })?;
    Ok(())
}

fn insert_capabilities(
    connection: &Connection,
    path: &Path,
    table: &str,
    package_id: i64,
    capabilities: &[BinaryCapability],
) -> Result<(), RepoError> {
    let query = format!(
        "INSERT INTO {table}(package_id, capability_name, constraint_text) VALUES(?1, ?2, ?3)"
    );
    for capability in capabilities {
        connection
            .execute(
                &query,
                params![package_id, capability.name, capability.constraint],
            )
            .map_err(|source| RepoError::Sql {
                path: path.to_path_buf(),
                source,
            })?;
    }
    Ok(())
}

fn dependency_kind_text(kind: DependencyKind) -> &'static str {
    match kind {
        DependencyKind::Runtime => "runtime",
        DependencyKind::Build => "build",
        DependencyKind::Optional => "optional",
        DependencyKind::Test => "test",
    }
}

fn compress_file(source: &Path, destination: &Path) -> Result<(), RepoError> {
    let mut input = File::open(source).map_err(|source_err| RepoError::Read {
        path: source.to_path_buf(),
        source: source_err,
    })?;
    let output = File::create(destination).map_err(|source_err| RepoError::Write {
        path: destination.to_path_buf(),
        source: source_err,
    })?;
    let mut encoder = zstd::Encoder::new(output, 19).map_err(|source_err| RepoError::Write {
        path: destination.to_path_buf(),
        source: source_err,
    })?;
    std::io::copy(&mut input, &mut encoder).map_err(|source_err| RepoError::Write {
        path: destination.to_path_buf(),
        source: source_err,
    })?;
    encoder.finish().map_err(|source_err| RepoError::Write {
        path: destination.to_path_buf(),
        source: source_err,
    })?;
    Ok(())
}

fn hash_file(path: &Path) -> Result<String, RepoError> {
    let mut file = File::open(path).map_err(|source| RepoError::Read {
        path: path.to_path_buf(),
        source,
    })?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 8192];
    loop {
        let read = file.read(&mut buffer).map_err(|source| RepoError::Read {
            path: path.to_path_buf(),
            source,
        })?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn hash_bytes(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

fn verify_digest(path: &str, expected: &str, bytes: &[u8]) -> Result<(), RepoError> {
    let actual = hash_bytes(bytes);
    if actual == expected.to_ascii_lowercase() {
        return Ok(());
    }
    Err(RepoError::DigestMismatch {
        path: path.to_owned(),
        expected: expected.to_owned(),
        actual,
    })
}

fn read_cached_unified_repo_state(
    repo_state_dir: &Path,
    repo_component: &str,
    channel_component: &str,
) -> Result<Option<CachedUnifiedRepoState>, RepoError> {
    let path = cached_unified_repo_state_path(repo_state_dir, repo_component, channel_component);
    if !path.exists() {
        return Ok(None);
    }
    read_toml(&path).map(Some)
}

fn write_cached_unified_repo_state(
    repo_state_dir: &Path,
    repo_component: &str,
    channel_component: &str,
    state: &CachedUnifiedRepoState,
) -> Result<(), RepoError> {
    let path = cached_unified_repo_state_path(repo_state_dir, repo_component, channel_component);
    write_toml(&path, state)
}

fn cached_unified_repo_state_path(
    repo_state_dir: &Path,
    repo_component: &str,
    channel_component: &str,
) -> PathBuf {
    repo_state_dir
        .join(repo_component)
        .join(format!("{channel_component}.toml"))
}

fn local_snapshot_package_dir(
    snapshot_root: &Path,
    manifest: &RecipeBundleManifest,
) -> Result<PathBuf, RepoError> {
    let package_component = safe_path_component(&manifest.package_name)?;
    let version_component = if manifest.epoch == 0 {
        format!("{}-{}", manifest.version, manifest.release)
    } else {
        format!(
            "epoch{}-{}-{}",
            manifest.epoch, manifest.version, manifest.release
        )
    };
    Ok(snapshot_root
        .join("packages")
        .join(package_component)
        .join(safe_path_component(&version_component)?))
}

fn write_toml<T: Serialize>(path: &Path, value: &T) -> Result<(), RepoError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|source| RepoError::Write {
            path: parent.to_path_buf(),
            source,
        })?;
    }
    let contents = toml::to_string_pretty(value).map_err(|source| RepoError::Serialize {
        path: path.to_path_buf(),
        source,
    })?;
    fs::write(path, contents).map_err(|source| RepoError::Write {
        path: path.to_path_buf(),
        source,
    })
}

fn write_bytes(path: &Path, bytes: &[u8]) -> Result<(), RepoError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|source| RepoError::Write {
            path: parent.to_path_buf(),
            source,
        })?;
    }
    fs::write(path, bytes).map_err(|source| RepoError::Write {
        path: path.to_path_buf(),
        source,
    })
}

fn copy_repo_file(source: &Path, destination: &Path) -> Result<(), RepoError> {
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent).map_err(|source_err| RepoError::Write {
            path: parent.to_path_buf(),
            source: source_err,
        })?;
    }
    let metadata = fs::symlink_metadata(source).map_err(|source_err| RepoError::Read {
        path: source.to_path_buf(),
        source: source_err,
    })?;
    if metadata.file_type().is_symlink() {
        let target = fs::read_link(source).map_err(|source_err| RepoError::Read {
            path: source.to_path_buf(),
            source: source_err,
        })?;
        symlink(&target, destination).map_err(|source_err| RepoError::Write {
            path: destination.to_path_buf(),
            source: source_err,
        })?;
    } else {
        fs::copy(source, destination).map_err(|source_err| RepoError::Write {
            path: destination.to_path_buf(),
            source: source_err,
        })?;
    }
    Ok(())
}

fn safe_path_component(value: &str) -> Result<String, RepoError> {
    if value.is_empty()
        || !value
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '.' | '+'))
    {
        return Err(RepoError::UnsafeRelativePath {
            path: value.to_owned(),
        });
    }
    Ok(value.to_owned())
}

fn sanitize_relative_path(path: &str) -> Result<PathBuf, RepoError> {
    let candidate = Path::new(path);
    if candidate.is_absolute() {
        return Err(RepoError::UnsafeRelativePath {
            path: path.to_owned(),
        });
    }
    let mut normalized = PathBuf::new();
    for component in candidate.components() {
        match component {
            std::path::Component::Normal(part) => normalized.push(part),
            _ => {
                return Err(RepoError::UnsafeRelativePath {
                    path: path.to_owned(),
                })
            }
        }
    }
    if normalized.as_os_str().is_empty() {
        return Err(RepoError::UnsafeRelativePath {
            path: path.to_owned(),
        });
    }
    Ok(normalized)
}

fn relative_path_string(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

fn current_timestamp_string() -> String {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
        .to_string()
}

fn default_revision_string() -> String {
    format!("rev-{}", current_timestamp_string())
}

fn http_get_bytes(url: &str) -> Result<Vec<u8>, RepoError> {
    let parsed = ParsedHttpUrl::parse(url)?;
    let mut stream = TcpStream::connect((parsed.host.as_str(), parsed.port)).map_err(|source| {
        RepoError::HttpConnect {
            url: url.to_owned(),
            source,
        }
    })?;
    let request = format!(
        "GET {} HTTP/1.1\r\nHost: {}\r\nConnection: close\r\nUser-Agent: sloppkg/0.1\r\nAccept: */*\r\n\r\n",
        parsed.path, parsed.authority
    );
    stream
        .write_all(request.as_bytes())
        .map_err(|source| RepoError::HttpRead {
            url: url.to_owned(),
            source,
        })?;
    let mut response = Vec::new();
    stream
        .read_to_end(&mut response)
        .map_err(|source| RepoError::HttpRead {
            url: url.to_owned(),
            source,
        })?;

    let header_end = response
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .ok_or_else(|| RepoError::HttpProtocol {
            url: url.to_owned(),
            reason: String::from("missing header terminator"),
        })?;
    let header_bytes = &response[..header_end];
    let body = response[(header_end + 4)..].to_vec();
    let header_text = std::str::from_utf8(header_bytes).map_err(|_| RepoError::HttpProtocol {
        url: url.to_owned(),
        reason: String::from("headers are not valid UTF-8"),
    })?;
    let mut lines = header_text.lines();
    let status_line = lines.next().ok_or_else(|| RepoError::HttpProtocol {
        url: url.to_owned(),
        reason: String::from("missing status line"),
    })?;
    let mut status_parts = status_line.split_whitespace();
    let _http_version = status_parts.next();
    let status_code = status_parts.next().ok_or_else(|| RepoError::HttpProtocol {
        url: url.to_owned(),
        reason: String::from("missing status code"),
    })?;
    if status_code != "200" {
        return Err(RepoError::HttpStatus {
            url: url.to_owned(),
            status: status_line.to_owned(),
        });
    }
    Ok(body)
}

#[derive(Debug)]
struct ParsedHttpUrl {
    authority: String,
    host: String,
    port: u16,
    path: String,
}

impl ParsedHttpUrl {
    fn parse(url: &str) -> Result<Self, RepoError> {
        let without_scheme =
            url.strip_prefix("http://")
                .ok_or_else(|| RepoError::UnsupportedRepoUrl {
                    url: url.to_owned(),
                    reason: String::from("only plain http:// URLs are supported"),
                })?;
        let (authority, path_part) = match without_scheme.split_once('/') {
            Some((authority, path)) => (authority, format!("/{}", path)),
            None => (without_scheme, String::from("/")),
        };
        if authority.is_empty() {
            return Err(RepoError::UnsupportedRepoUrl {
                url: url.to_owned(),
                reason: String::from("missing host"),
            });
        }
        let (host, port) = match authority.split_once(':') {
            Some((host, port)) => (
                host.to_owned(),
                port.parse::<u16>()
                    .map_err(|_| RepoError::UnsupportedRepoUrl {
                        url: url.to_owned(),
                        reason: String::from("invalid port"),
                    })?,
            ),
            None => (authority.to_owned(), 80),
        };
        if host.is_empty() {
            return Err(RepoError::UnsupportedRepoUrl {
                url: url.to_owned(),
                reason: String::from("missing host"),
            });
        }
        Ok(Self {
            authority: authority.to_owned(),
            host,
            port,
            path: path_part,
        })
    }

    fn join(&self, relative: &str) -> Result<String, RepoError> {
        let rel = sanitize_relative_path(relative)?;
        let base = self.path.trim_end_matches('/');
        let rel_str = relative_path_string(&rel);
        let joined = if base.is_empty() || base == "/" {
            format!("/{rel_str}")
        } else {
            format!("{base}/{rel_str}")
        };
        Ok(format!("http://{}{}", self.authority, joined))
    }
}

#[derive(Debug, Serialize)]
struct LocalRecipeRepoMetadata {
    name: String,
    kind: RepoKind,
}

fn read_existing_binary_repo_name(root: &Path) -> Result<Option<String>, RepoError> {
    let path = root.join("repo.toml");
    if !path.exists() {
        return Ok(None);
    }
    let repo = read_toml::<RawRepo>(&path)?;
    if repo.kind != RepoKind::Binary {
        return Err(RepoError::UnsupportedRepoKind {
            path,
            found: repo.kind,
        });
    }
    Ok(Some(repo.name))
}

fn read_toml<T: for<'de> Deserialize<'de>>(path: &Path) -> Result<T, RepoError> {
    let contents = fs::read_to_string(path).map_err(|source| RepoError::Read {
        path: path.to_path_buf(),
        source,
    })?;
    toml::from_str(&contents).map_err(|source| RepoError::Parse {
        path: path.to_path_buf(),
        source,
    })
}

fn raw_dependency_to_dependency(
    raw: RawDependency,
) -> Result<Dependency, sloppkg_types::VersionParseError> {
    Ok(Dependency {
        name: raw.name,
        constraint: Constraint::parse(raw.constraint.as_deref().unwrap_or("*"))?,
        kind: raw.kind,
        reason: raw.reason,
        feature: raw.feature,
    })
}

fn raw_capability_to_capability(
    raw: RawCapability,
) -> Result<Capability, sloppkg_types::VersionParseError> {
    Ok(Capability {
        name: raw.name,
        constraint: Constraint::parse(raw.constraint.as_deref().unwrap_or("*"))?,
    })
}

#[derive(Clone, Debug)]
struct IndexedBinaryPackage {
    info: BinaryPackageInfo,
    archive_path: String,
    archive_size: u64,
    archive_sha256: String,
}

#[derive(Debug, Serialize)]
struct BinaryRepoMetadata {
    format_version: u32,
    name: String,
    kind: RepoKind,
    generated_at: u64,
    architectures: Vec<String>,
    compression: String,
    signature_type: String,
}

#[derive(Debug, Deserialize)]
struct RawRepo {
    name: String,
    kind: RepoKind,
}

#[derive(Debug, Deserialize)]
struct RawPackageFile {
    package: RawPackageSection,
    #[serde(default)]
    sources: Vec<RawSource>,
    build: RawBuild,
    install: RawInstall,
    bootstrap: Option<RawBootstrap>,
    #[serde(default)]
    dependencies: Vec<RawDependency>,
    #[serde(default)]
    dependency_groups: Vec<RawDependencyGroup>,
    #[serde(default)]
    provides: Vec<RawCapability>,
    #[serde(default)]
    conflicts: Vec<RawCapability>,
    #[serde(default)]
    replaces: Vec<RawCapability>,
}

#[derive(Debug, Deserialize)]
struct RawPackageSection {
    name: String,
    #[serde(default)]
    epoch: Option<u64>,
    version: String,
    #[serde(deserialize_with = "string_or_int")]
    release: String,
    summary: String,
    description: String,
    license: String,
    homepage: Option<String>,
    #[serde(default = "default_architectures")]
    architectures: Vec<String>,
}

fn default_architectures() -> Vec<String> {
    vec![String::from("aarch64")]
}

#[derive(Debug, Deserialize)]
struct RawSource {
    kind: String,
    url: String,
    sha256: String,
    filename: Option<String>,
    strip_components: Option<usize>,
    destination: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawBuild {
    system: String,
    out_of_tree: Option<bool>,
    directory: Option<String>,
    env: Option<BTreeMap<String, String>>,
    #[serde(default)]
    configure: Vec<String>,
    #[serde(default)]
    build: Vec<String>,
    #[serde(default)]
    install: Vec<String>,
    jobs: Option<usize>,
}

#[derive(Debug, Deserialize)]
struct RawInstall {
    prefix: String,
    sysconfdir: Option<String>,
    localstatedir: Option<String>,
    #[serde(default)]
    owned_prefixes: Vec<String>,
    strip_binaries: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct RawBootstrap {
    sysroot: String,
    #[serde(default)]
    stages: Vec<RawBootstrapStage>,
}

#[derive(Debug, Deserialize)]
struct RawBootstrapStage {
    name: String,
    #[serde(default)]
    packages: Vec<String>,
    #[serde(default)]
    depends_on: Vec<String>,
    env: Option<BTreeMap<String, String>>,
}

#[derive(Debug, Deserialize)]
struct RawDependency {
    name: String,
    constraint: Option<String>,
    #[serde(default = "default_dependency_kind")]
    kind: DependencyKind,
    reason: Option<String>,
    feature: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawDependencyGroup {
    #[serde(default = "default_dependency_kind")]
    kind: DependencyKind,
    #[serde(default)]
    one_of: Vec<RawDependency>,
}

#[derive(Debug, Deserialize)]
struct RawCapability {
    name: String,
    constraint: Option<String>,
}

fn default_dependency_kind() -> DependencyKind {
    DependencyKind::Runtime
}

fn string_or_int<'de, D>(deserializer: D) -> Result<String, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::de::{Error, Visitor};
    use std::fmt;

    struct StringOrIntVisitor;

    impl<'de> Visitor<'de> for StringOrIntVisitor {
        type Value = String;

        fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
            formatter.write_str("string or integer")
        }

        fn visit_u64<E>(self, value: u64) -> Result<Self::Value, E>
        where
            E: Error,
        {
            Ok(value.to_string())
        }

        fn visit_i64<E>(self, value: i64) -> Result<Self::Value, E>
        where
            E: Error,
        {
            Ok(value.to_string())
        }

        fn visit_str<E>(self, value: &str) -> Result<Self::Value, E>
        where
            E: Error,
        {
            Ok(value.to_owned())
        }

        fn visit_string<E>(self, value: String) -> Result<Self::Value, E>
        where
            E: Error,
        {
            Ok(value)
        }
    }

    deserializer.deserialize_any(StringOrIntVisitor)
}

#[cfg(test)]
mod tests {
    use std::path::Path;
    use std::time::{SystemTime, UNIX_EPOCH};

    use rusqlite::Connection;
    use sloppkg_types::{
        BinaryCapability, BinaryDependency, BinaryDependencyGroup, DependencyKind, RepoCapability,
        RepoKind, RepoTrustMode,
    };

    use super::{
        export_unified_recipe_repo, generate_binary_repo_index, read_recipe_bundle_manifest,
        read_recipe_snapshot_index, read_unified_repo_metadata, BinaryPackageInfo,
    };

    #[test]
    fn generates_binary_repo_index_from_cached_archives() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("sloppkg-repo-test-{unique}"));
        let archive_dir = root.join("hello-stage");
        let archive_path = archive_dir.join("hello-stage-0.1.0-1-aarch64.sloppkg.tar.zst");
        std::fs::create_dir_all(&archive_dir).unwrap();

        write_test_archive(
            &archive_path,
            &BinaryPackageInfo {
                package_name: String::from("hello-stage"),
                epoch: 0,
                version: String::from("0.1.0"),
                release: String::from("1"),
                arch: String::from("aarch64"),
                repo_name: String::from("workspace"),
                source_path: String::from("hello-stage/0.1.0-1/package.toml"),
                summary: String::from("hello"),
                description: String::from("hello stage package"),
                license: String::from("MIT"),
                homepage: Some(String::from("https://example.invalid/hello-stage")),
                owned_prefixes: vec![String::from("/usr/local")],
                dependencies: vec![BinaryDependency {
                    name: String::from("libc"),
                    constraint: String::from(">= 1.0.0-0"),
                    kind: DependencyKind::Runtime,
                    reason: Some(String::from("runtime")),
                    feature: None,
                }],
                dependency_groups: vec![BinaryDependencyGroup {
                    kind: DependencyKind::Runtime,
                    one_of: vec![
                        BinaryDependency {
                            name: String::from("openssl"),
                            constraint: String::from(">= 3.0.0-0"),
                            kind: DependencyKind::Runtime,
                            reason: None,
                            feature: None,
                        },
                        BinaryDependency {
                            name: String::from("libressl"),
                            constraint: String::from(">= 4.0.0-0"),
                            kind: DependencyKind::Runtime,
                            reason: None,
                            feature: None,
                        },
                    ],
                }],
                provides: vec![BinaryCapability {
                    name: String::from("hello-stage-virtual"),
                    constraint: String::from("= 0.1.0-1"),
                }],
                conflicts: Vec::new(),
                replaces: Vec::new(),
            },
        );

        let report = generate_binary_repo_index(&root, Some("local-cache")).unwrap();
        assert_eq!(report.package_count, 1);
        assert!(report.repo_toml_path.exists());
        assert!(report.index_path.exists());

        let sqlite_path = root.join("repodata/index.sqlite");
        let compressed = std::fs::File::open(&report.index_path).unwrap();
        let mut decoder = zstd::Decoder::new(compressed).unwrap();
        let mut output = std::fs::File::create(&sqlite_path).unwrap();
        std::io::copy(&mut decoder, &mut output).unwrap();

        let connection = Connection::open(&sqlite_path).unwrap();
        let package_row = connection
            .query_row(
                "SELECT name, archive_path, archive_sha256 FROM packages",
                [],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(package_row.0, "hello-stage");
        assert_eq!(
            package_row.1,
            "hello-stage/hello-stage-0.1.0-1-aarch64.sloppkg.tar.zst"
        );
        assert!(!package_row.2.is_empty());

        let dependency_count: i64 = connection
            .query_row("SELECT COUNT(*) FROM dependencies", [], |row| row.get(0))
            .unwrap();
        let group_member_count: i64 = connection
            .query_row("SELECT COUNT(*) FROM dependency_group_members", [], |row| {
                row.get(0)
            })
            .unwrap();
        let provide_count: i64 = connection
            .query_row("SELECT COUNT(*) FROM provides", [], |row| row.get(0))
            .unwrap();
        assert_eq!(dependency_count, 1);
        assert_eq!(group_member_count, 2);
        assert_eq!(provide_count, 1);

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn reads_unified_repo_metadata_and_recipe_manifests() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("sloppkg-unified-repo-test-{unique}"));
        std::fs::create_dir_all(root.join("recipes/by-name/gcc/14.3.0-1")).unwrap();

        std::fs::write(
            root.join("repo.toml"),
            r#"
format_version = 1
name = "slopos-main"
kind = "unified"
generated_at = "2026-01-01T00:00:00Z"
default_channel = "stable"
capabilities = ["recipes"]

[recipes.channels.stable]
current_revision = "2026.01.01"
index_path = "recipes/index/stable.toml"
index_sha256 = "abc123"

[trust]
mode = "digest-pinned"
"#,
        )
        .unwrap();

        std::fs::write(
            root.join("recipes/index-stable.toml"),
            r#"
format_version = 1
repo_name = "slopos-main"
channel = "stable"
revision = "2026.01.01"
generated_at = "2026-01-01T00:00:00Z"

[[recipes]]
name = "gcc"

[[recipes.versions]]
version = "14.3.0"
release = "1"
manifest_path = "recipes/by-name/gcc/14.3.0-1/manifest.toml"
manifest_sha256 = "def456"
"#,
        )
        .unwrap();

        std::fs::write(
            root.join("recipes/by-name/gcc/14.3.0-1/manifest.toml"),
            r#"
format_version = 1
package_name = "gcc"
version = "14.3.0"
release = "1"

[[files]]
path = "package.toml"
sha256 = "111"

[[files]]
path = "build.sh"
sha256 = "222"
"#,
        )
        .unwrap();

        let metadata = read_unified_repo_metadata(&root.join("repo.toml")).unwrap();
        assert_eq!(metadata.kind, RepoKind::Unified);
        assert_eq!(metadata.default_channel, "stable");
        assert_eq!(metadata.capabilities, vec![RepoCapability::Recipes]);
        assert_eq!(metadata.trust.mode, RepoTrustMode::DigestPinned);

        let index = read_recipe_snapshot_index(&root.join("recipes/index-stable.toml")).unwrap();
        assert_eq!(index.channel, "stable");
        assert_eq!(index.recipes.len(), 1);
        assert_eq!(index.recipes[0].name, "gcc");
        assert_eq!(
            index.recipes[0].versions[0].manifest_path,
            "recipes/by-name/gcc/14.3.0-1/manifest.toml"
        );

        let manifest =
            read_recipe_bundle_manifest(&root.join("recipes/by-name/gcc/14.3.0-1/manifest.toml"))
                .unwrap();
        assert_eq!(manifest.package_name, "gcc");
        assert_eq!(manifest.files.len(), 2);
        assert_eq!(manifest.files[1].path, "build.sh");

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn exports_local_recipe_repo_to_unified_layout() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("sloppkg-export-repo-test-{unique}"));
        let repo_root = root.join("workspace");
        let package_dir = repo_root.join("demo").join("1.2.3-1");
        let output_root = root.join("exported");

        std::fs::create_dir_all(package_dir.join("payload")).unwrap();
        std::fs::write(
            repo_root.join("repo.toml"),
            "name = \"workspace\"\nkind = \"recipe\"\n",
        )
        .unwrap();
        std::fs::write(
            package_dir.join("package.toml"),
            r#"[package]
name = "demo"
version = "1.2.3"
release = 1
summary = "demo"
description = "demo"
license = "MIT"
architectures = ["aarch64"]

[[sources]]
kind = "file"
url = "payload"
sha256 = "local"
destination = "payload"

[build]
system = "custom"
out_of_tree = true
directory = "payload"
install = ["mkdir -p \"$PKG_DESTDIR/usr/local/share/demo\"","install -m 0644 \"$PKG_SOURCE_DIR/message.txt\" \"$PKG_DESTDIR/usr/local/share/demo/message.txt\""]

[install]
prefix = "/usr/local"
owned_prefixes = ["/usr/local"]
"#,
        )
        .unwrap();
        std::fs::write(package_dir.join("build.sh"), "#!/bin/sh\necho demo\n").unwrap();
        std::fs::write(package_dir.join("payload/message.txt"), "hello\n").unwrap();

        let report =
            export_unified_recipe_repo(&repo_root, &output_root, "stable", Some("test-rev"))
                .unwrap();
        assert_eq!(report.repo_name, "workspace");
        assert_eq!(report.package_count, 1);
        assert_eq!(report.version_count, 1);
        assert_eq!(report.file_count, 3);

        let metadata = read_unified_repo_metadata(&output_root.join("repo.toml")).unwrap();
        assert_eq!(metadata.default_channel, "stable");
        assert_eq!(
            metadata.recipes.channels["stable"].index_path,
            "recipes/index/stable.toml"
        );

        let index =
            read_recipe_snapshot_index(&output_root.join("recipes/index/stable.toml")).unwrap();
        assert_eq!(index.revision, "test-rev");
        assert_eq!(index.recipes.len(), 1);
        assert_eq!(
            index.recipes[0].versions[0].manifest_path,
            "recipes/by-name/demo/1.2.3-1/manifest.toml"
        );

        let manifest = read_recipe_bundle_manifest(
            &output_root.join("recipes/by-name/demo/1.2.3-1/manifest.toml"),
        )
        .unwrap();
        assert_eq!(manifest.package_name, "demo");
        assert_eq!(manifest.files.len(), 3);
        assert!(output_root
            .join("recipes/by-name/demo/1.2.3-1/package.toml")
            .exists());
        assert!(output_root
            .join("recipes/by-name/demo/1.2.3-1/build.sh")
            .exists());
        assert!(output_root
            .join("recipes/by-name/demo/1.2.3-1/payload/message.txt")
            .exists());

        let _ = std::fs::remove_dir_all(root);
    }

    fn write_test_archive(path: &Path, info: &BinaryPackageInfo) {
        let stage_root = path.parent().unwrap().join("stage");
        let payload_root = stage_root.join("root");
        std::fs::create_dir_all(payload_root.join("usr/local/bin")).unwrap();
        std::fs::write(
            payload_root.join("usr/local/bin/hello-stage"),
            "#!/bin/sh\necho hello\n",
        )
        .unwrap();
        std::fs::write(
            stage_root.join("manifest.json"),
            r#"{"package_name":"hello-stage","version":"0.1.0-1","entries":[]}"#,
        )
        .unwrap();
        std::fs::write(
            stage_root.join("pkg-info.toml"),
            toml::to_string_pretty(info).unwrap(),
        )
        .unwrap();

        let tar_path = stage_root.join("payload.tar");
        let tar_file = std::fs::File::create(&tar_path).unwrap();
        let mut builder = tar::Builder::new(tar_file);
        builder
            .append_path_with_name(stage_root.join("pkg-info.toml"), "pkg-info.toml")
            .unwrap();
        builder
            .append_path_with_name(stage_root.join("manifest.json"), "manifest.json")
            .unwrap();
        builder.append_dir_all("root", &payload_root).unwrap();
        builder.finish().unwrap();

        let mut input = std::fs::File::open(&tar_path).unwrap();
        let output = std::fs::File::create(path).unwrap();
        let mut encoder = zstd::Encoder::new(output, 19).unwrap();
        std::io::copy(&mut input, &mut encoder).unwrap();
        encoder.finish().unwrap();

        let _ = std::fs::remove_dir_all(stage_root);
    }
}
