use std::fs;
use std::fs::File;
use std::io::Read;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde::Serialize;
use sha2::{Digest, Sha256};
use sloppkg_types::{
    BinaryCapability, BinaryDependency, BinaryDependencyGroup, BinaryPackageInfo, PackageManifest,
    PackageRecord,
};
use thiserror::Error;
use walkdir::WalkDir;

#[derive(Debug, Error)]
pub enum BuildError {
    #[error("I/O failure at {path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("missing cached source archive: {0}")]
    MissingCachedSource(PathBuf),
    #[error("remote source {0} requires a real sha256")]
    UnverifiableRemoteSource(String),
    #[error("checksum mismatch for {path}: expected {expected}, got {actual}")]
    ChecksumMismatch {
        path: PathBuf,
        expected: String,
        actual: String,
    },
    #[error("failed to fetch {url} into {path}")]
    FetchCommandFailed { url: String, path: PathBuf },
    #[error("unsupported source kind: {0}")]
    UnsupportedSourceKind(String),
    #[error("unsupported build system: {0}")]
    UnsupportedBuildSystem(String),
    #[error("build command failed in {cwd}: {command}")]
    CommandFailed { cwd: PathBuf, command: String },
    #[error("recipe path has no parent: {0}")]
    InvalidRecipePath(PathBuf),
    #[error("build directory does not exist: {0}")]
    MissingBuildDirectory(PathBuf),
    #[error("manifest serialization failed: {0}")]
    ManifestSerialize(#[from] serde_json::Error),
    #[error("package metadata serialization failed: {0}")]
    PackageInfoSerialize(#[from] toml::ser::Error),
}

#[derive(Clone, Debug, Serialize)]
pub struct BuildReport {
    pub transaction_id: i64,
    pub package_name: String,
    pub version: String,
    pub work_dir: PathBuf,
    pub source_dir: PathBuf,
    pub build_dir: PathBuf,
    pub stage_root: PathBuf,
    pub destdir: PathBuf,
    pub manifest_path: PathBuf,
    pub manifest_entries: usize,
    pub package_info_path: PathBuf,
    pub package_archive_path: PathBuf,
    pub package_archive_sha256: String,
    pub package_archive_size: u64,
}

#[derive(Clone, Debug, Serialize)]
pub struct FetchEntryReport {
    pub kind: String,
    pub source_url: String,
    pub local_path: Option<PathBuf>,
    pub action: String,
    pub checksum: Option<String>,
    pub size: Option<u64>,
}

#[derive(Clone, Debug, Serialize)]
pub struct SourceFetchReport {
    pub package_name: String,
    pub version: String,
    pub entries: Vec<FetchEntryReport>,
}

pub fn stage_package(
    package: &PackageRecord,
    distfiles_dir: &Path,
    build_root: &Path,
    package_cache_root: &Path,
    transaction_id: i64,
    extra_env: &[(String, String)],
) -> Result<BuildReport, BuildError> {
    let work_dir = build_root.join(format!(
        "{}-{}-tx{}",
        sanitize(&package.package.name),
        sanitize(&package.package.evr.to_string()),
        transaction_id
    ));
    let source_root = work_dir.join("sources");
    let build_dir_root = work_dir.join("build");
    let stage_root = work_dir.join("stage");
    let destdir = stage_root.join("root");
    let manifest_path = stage_root.join("manifest.json");
    let package_info_path = stage_root.join("pkg-info.toml");

    if work_dir.exists() {
        fs::remove_dir_all(&work_dir).map_err(|source| BuildError::Io {
            path: work_dir.clone(),
            source,
        })?;
    }

    for path in [&source_root, &build_dir_root, &destdir] {
        fs::create_dir_all(path).map_err(|source| BuildError::Io {
            path: path.clone(),
            source,
        })?;
    }

    materialize_sources(package, distfiles_dir, &source_root)?;

    let source_dir = resolve_source_dir(package, &source_root)?;
    let build_dir = if package.build.out_of_tree {
        build_dir_root.clone()
    } else {
        source_dir.clone()
    };
    fs::create_dir_all(&build_dir).map_err(|source| BuildError::Io {
        path: build_dir.clone(),
        source,
    })?;

    run_build(package, &source_dir, &build_dir, &destdir, extra_env)?;

    let manifest = build_manifest(package, &destdir)?;
    let manifest_json = serde_json::to_vec_pretty(&manifest)?;
    fs::write(&manifest_path, manifest_json).map_err(|source| BuildError::Io {
        path: manifest_path.clone(),
        source,
    })?;

    let package_info = build_package_info(package);
    let package_info_toml = toml::to_string_pretty(&package_info)?;
    fs::write(&package_info_path, package_info_toml).map_err(|source| BuildError::Io {
        path: package_info_path.clone(),
        source,
    })?;

    let package_archive_path = emit_binary_package(package, package_cache_root, &stage_root)?;
    let package_archive_sha256 = hash_file(&package_archive_path)?;
    let package_archive_size = fs::metadata(&package_archive_path)
        .map_err(|source| BuildError::Io {
            path: package_archive_path.clone(),
            source,
        })?
        .len();

    Ok(BuildReport {
        transaction_id,
        package_name: package.package.name.clone(),
        version: package.package.evr.to_string(),
        work_dir,
        source_dir,
        build_dir,
        stage_root,
        destdir,
        manifest_path,
        manifest_entries: manifest.entries.len(),
        package_info_path,
        package_archive_path,
        package_archive_sha256,
        package_archive_size,
    })
}

pub fn fetch_package_sources(
    package: &PackageRecord,
    distfiles_dir: &Path,
) -> Result<SourceFetchReport, BuildError> {
    let recipe_dir = package
        .recipe_path
        .parent()
        .ok_or_else(|| BuildError::InvalidRecipePath(package.recipe_path.clone()))?;
    fs::create_dir_all(distfiles_dir).map_err(|source| BuildError::Io {
        path: distfiles_dir.to_path_buf(),
        source,
    })?;

    let mut entries = Vec::new();
    for source in &package.sources {
        match source.kind.as_str() {
            "file" => {
                let source_path = resolve_local_source_path(source, recipe_dir);
                if source_path.exists() {
                    entries.push(FetchEntryReport {
                        kind: source.kind.clone(),
                        source_url: source.url.clone(),
                        local_path: Some(source_path),
                        action: String::from("local"),
                        checksum: None,
                        size: None,
                    });
                    continue;
                }
                if !is_remote_url(&source.url) {
                    return Err(BuildError::Io {
                        path: source_path,
                        source: std::io::Error::new(
                            std::io::ErrorKind::NotFound,
                            "source file not found",
                        ),
                    });
                }

                let cached_path = resolve_cached_source_path(source, distfiles_dir);
                let action = ensure_remote_source_cached(source, &cached_path)?;
                let size = fs::metadata(&cached_path)
                    .map_err(|source| BuildError::Io {
                        path: cached_path.clone(),
                        source,
                    })?
                    .len();
                entries.push(FetchEntryReport {
                    kind: source.kind.clone(),
                    source_url: source.url.clone(),
                    local_path: Some(cached_path),
                    action,
                    checksum: Some(source.sha256.clone()),
                    size: Some(size),
                });
            }
            "archive" => {
                let archive_path = resolve_local_source_path(source, recipe_dir);
                if archive_path.exists() {
                    entries.push(FetchEntryReport {
                        kind: source.kind.clone(),
                        source_url: source.url.clone(),
                        local_path: Some(archive_path),
                        action: String::from("local"),
                        checksum: None,
                        size: None,
                    });
                    continue;
                }
                let cached_path = resolve_cached_source_path(source, distfiles_dir);
                let action = ensure_remote_source_cached(source, &cached_path)?;
                let size = fs::metadata(&cached_path)
                    .map_err(|source| BuildError::Io {
                        path: cached_path.clone(),
                        source,
                    })?
                    .len();
                entries.push(FetchEntryReport {
                    kind: source.kind.clone(),
                    source_url: source.url.clone(),
                    local_path: Some(cached_path),
                    action,
                    checksum: Some(source.sha256.clone()),
                    size: Some(size),
                });
            }
            other => return Err(BuildError::UnsupportedSourceKind(other.to_owned())),
        }
    }

    Ok(SourceFetchReport {
        package_name: package.package.name.clone(),
        version: package.package.evr.to_string(),
        entries,
    })
}

fn materialize_sources(
    package: &PackageRecord,
    distfiles_dir: &Path,
    source_root: &Path,
) -> Result<(), BuildError> {
    let recipe_dir = package
        .recipe_path
        .parent()
        .ok_or_else(|| BuildError::InvalidRecipePath(package.recipe_path.clone()))?;

    if package.sources.is_empty() {
        copy_dir_contents(recipe_dir, source_root)?;
        return Ok(());
    }

    for source in &package.sources {
        match source.kind.as_str() {
            "file" => {
                let source_path = if resolve_local_source_path(source, recipe_dir).exists() {
                    resolve_local_source_path(source, recipe_dir)
                } else if is_remote_url(&source.url) {
                    let cached_path = resolve_cached_source_path(source, distfiles_dir);
                    if !cached_path.exists() {
                        return Err(BuildError::MissingCachedSource(cached_path));
                    }
                    ensure_source_checksum(source, &cached_path)?;
                    cached_path
                } else {
                    resolve_local_source_path(source, recipe_dir)
                };
                let destination_name = source
                    .destination
                    .clone()
                    .or_else(|| {
                        source_path
                            .file_name()
                            .map(|name| name.to_string_lossy().into_owned())
                    })
                    .unwrap_or_else(|| String::from("source"));
                let destination = source_root.join(destination_name);
                copy_path(&source_path, &destination)?;
            }
            "archive" => {
                let archive_path = if resolve_local_source_path(source, recipe_dir).exists() {
                    resolve_local_source_path(source, recipe_dir)
                } else {
                    resolve_cached_source_path(source, distfiles_dir)
                };
                if !archive_path.exists() {
                    return Err(BuildError::MissingCachedSource(archive_path));
                }
                ensure_source_checksum(source, &archive_path)?;
                extract_archive(&archive_path, source_root, source.strip_components)?;
            }
            other => return Err(BuildError::UnsupportedSourceKind(other.to_owned())),
        }
    }

    Ok(())
}

fn resolve_cached_source_path(source: &sloppkg_types::SourceSpec, distfiles_dir: &Path) -> PathBuf {
    distfiles_dir.join(
        source
            .filename
            .clone()
            .or_else(|| source.url.rsplit('/').next().map(|name| name.to_owned()))
            .unwrap_or_else(|| String::from("source.tar")),
    )
}

fn resolve_local_source_path(source: &sloppkg_types::SourceSpec, recipe_dir: &Path) -> PathBuf {
    let url_path = Path::new(&source.url);
    if url_path.is_absolute() {
        url_path.to_path_buf()
    } else {
        recipe_dir.join(&source.url)
    }
}

fn is_remote_url(url: &str) -> bool {
    url.starts_with("http://") || url.starts_with("https://")
}

fn ensure_remote_source_cached(
    source: &sloppkg_types::SourceSpec,
    cached_path: &Path,
) -> Result<String, BuildError> {
    if source.sha256 == "local" {
        return Err(BuildError::UnverifiableRemoteSource(source.url.clone()));
    }

    if cached_path.exists() {
        if ensure_source_checksum(source, cached_path).is_ok() {
            return Ok(String::from("cached"));
        }
        fs::remove_file(cached_path).map_err(|source| BuildError::Io {
            path: cached_path.to_path_buf(),
            source,
        })?;
    }

    download_source(source, cached_path)?;
    ensure_source_checksum(source, cached_path)?;
    Ok(String::from("downloaded"))
}

fn ensure_source_checksum(
    source: &sloppkg_types::SourceSpec,
    path: &Path,
) -> Result<(), BuildError> {
    if source.sha256 == "local" {
        return Ok(());
    }
    let actual = hash_file(path)?;
    if actual != source.sha256 {
        return Err(BuildError::ChecksumMismatch {
            path: path.to_path_buf(),
            expected: source.sha256.clone(),
            actual,
        });
    }
    Ok(())
}

fn download_source(
    source: &sloppkg_types::SourceSpec,
    destination: &Path,
) -> Result<(), BuildError> {
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent).map_err(|source| BuildError::Io {
            path: parent.to_path_buf(),
            source,
        })?;
    }

    let tmp_path = destination.with_extension(format!(
        "{}.part",
        destination
            .extension()
            .and_then(|ext| ext.to_str())
            .unwrap_or("download")
    ));
    let script = r#"
import pathlib
import shutil
import sys
import urllib.request

url = sys.argv[1]
tmp_path = pathlib.Path(sys.argv[2])
final_path = pathlib.Path(sys.argv[3])
tmp_path.parent.mkdir(parents=True, exist_ok=True)
with urllib.request.urlopen(url, timeout=120) as response, tmp_path.open('wb') as out:
    shutil.copyfileobj(response, out)
tmp_path.replace(final_path)
"#;
    let attempts: [(&str, Vec<String>); 3] = [
        (
            "curl",
            vec![
                String::from("-L"),
                String::from("--fail"),
                String::from("--silent"),
                String::from("--show-error"),
                String::from("-o"),
                tmp_path.display().to_string(),
                source.url.clone(),
            ],
        ),
        (
            "wget",
            vec![
                String::from("-O"),
                tmp_path.display().to_string(),
                source.url.clone(),
            ],
        ),
        (
            "python3",
            vec![
                String::from("-c"),
                script.to_owned(),
                source.url.clone(),
                tmp_path.display().to_string(),
                destination.display().to_string(),
            ],
        ),
    ];

    for (program, args) in attempts {
        let status = match Command::new(program)
            .env("PATH", build_path())
            .args(&args)
            .status()
        {
            Ok(status) => status,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => continue,
            Err(source_err) => {
                return Err(BuildError::Io {
                    path: destination.to_path_buf(),
                    source: source_err,
                })
            }
        };
        if !status.success() {
            let _ = fs::remove_file(&tmp_path);
            continue;
        }
        if program != "python3" {
            fs::rename(&tmp_path, destination).map_err(|source| BuildError::Io {
                path: destination.to_path_buf(),
                source,
            })?;
        }
        return Ok(());
    }
    let _ = fs::remove_file(&tmp_path);
    Err(BuildError::FetchCommandFailed {
        url: source.url.clone(),
        path: destination.to_path_buf(),
    })
}

fn resolve_source_dir(package: &PackageRecord, source_root: &Path) -> Result<PathBuf, BuildError> {
    let source_dir = if let Some(directory) = &package.build.directory {
        source_root.join(directory)
    } else {
        let children = fs::read_dir(source_root)
            .map_err(|source| BuildError::Io {
                path: source_root.to_path_buf(),
                source,
            })?
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .collect::<Vec<_>>();
        if children.len() == 1 && children[0].is_dir() {
            children[0].clone()
        } else {
            source_root.to_path_buf()
        }
    };

    if !source_dir.exists() {
        return Err(BuildError::MissingBuildDirectory(source_dir));
    }

    Ok(source_dir)
}

fn run_build(
    package: &PackageRecord,
    source_dir: &Path,
    build_dir: &Path,
    destdir: &Path,
    extra_env: &[(String, String)],
) -> Result<(), BuildError> {
    let jobs = package.build.jobs.max(
        std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(1),
    );
    let mut envs = vec![
        (String::from("PKG_NAME"), package.package.name.clone()),
        (String::from("PKG_VERSION"), package.package.evr.to_string()),
        (
            String::from("PKG_SOURCE_DIR"),
            source_dir.display().to_string(),
        ),
        (
            String::from("PKG_BUILD_DIR"),
            build_dir.display().to_string(),
        ),
        (String::from("PKG_DESTDIR"), destdir.display().to_string()),
        (String::from("PREFIX"), package.install.prefix.clone()),
        (
            String::from("SYSCONFDIR"),
            package.install.sysconfdir.clone(),
        ),
        (
            String::from("LOCALSTATEDIR"),
            package.install.localstatedir.clone(),
        ),
        (String::from("BUILD_JOBS"), jobs.to_string()),
        (String::from("PATH"), build_path()),
    ];
    envs.extend(package.build.env.iter().cloned());
    envs.extend(extra_env.iter().cloned());

    match package.build.system.as_str() {
        "custom" => {
            for command in &package.build.build {
                run_shell(command, build_dir, &envs)?;
            }
            for command in &package.build.install {
                run_shell(command, build_dir, &envs)?;
            }
        }
        "gnu" => {
            let mut configure = format!(
                "\"$PKG_SOURCE_DIR/configure\" --prefix=\"$PREFIX\" --sysconfdir=\"$SYSCONFDIR\" --localstatedir=\"$LOCALSTATEDIR\""
            );
            if !package.build.configure.is_empty() {
                configure.push(' ');
                configure.push_str(&package.build.configure.join(" "));
            }
            run_shell(&configure, build_dir, &envs)?;

            if package.build.build.is_empty() {
                run_shell("make -j\"$BUILD_JOBS\"", build_dir, &envs)?;
            } else {
                for command in &package.build.build {
                    run_shell(command, build_dir, &envs)?;
                }
            }

            if package.build.install.is_empty() {
                run_shell("make DESTDIR=\"$PKG_DESTDIR\" install", build_dir, &envs)?;
            } else {
                for command in &package.build.install {
                    run_shell(command, build_dir, &envs)?;
                }
            }
        }
        other => return Err(BuildError::UnsupportedBuildSystem(other.to_owned())),
    }

    Ok(())
}

fn build_path() -> String {
    let managed_prefix =
        String::from("/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
    match std::env::var("PATH") {
        Ok(current) if !current.is_empty() => format!("{managed_prefix}:{current}"),
        _ => managed_prefix,
    }
}

fn run_shell(command: &str, cwd: &Path, envs: &[(String, String)]) -> Result<(), BuildError> {
    let mut process = Command::new("/bin/bash");
    process
        .arg("-c")
        .arg(format!("set -euo pipefail; {command}"));
    process.current_dir(cwd);
    for (key, value) in envs {
        process.env(key, value);
    }
    let status = process.status().map_err(|source| BuildError::Io {
        path: cwd.to_path_buf(),
        source,
    })?;
    if !status.success() {
        return Err(BuildError::CommandFailed {
            cwd: cwd.to_path_buf(),
            command: command.to_owned(),
        });
    }
    Ok(())
}

fn build_manifest(package: &PackageRecord, destdir: &Path) -> Result<PackageManifest, BuildError> {
    let mut entries = Vec::new();
    for entry in WalkDir::new(destdir)
        .min_depth(1)
        .into_iter()
        .filter_map(Result::ok)
    {
        let path = entry.path();
        let metadata = fs::symlink_metadata(path).map_err(|source| BuildError::Io {
            path: path.to_path_buf(),
            source,
        })?;
        let relative = path.strip_prefix(destdir).unwrap_or(path);
        let manifest_path = format!("/{}", relative.display());
        let file_type = if metadata.file_type().is_dir() {
            String::from("dir")
        } else if metadata.file_type().is_symlink() {
            String::from("symlink")
        } else {
            String::from("file")
        };
        let size = metadata.len();
        let sha256 = if metadata.file_type().is_file() {
            Some(hash_file(path)?)
        } else {
            None
        };
        let link_target = if metadata.file_type().is_symlink() {
            Some(
                fs::read_link(path)
                    .map_err(|source| BuildError::Io {
                        path: path.to_path_buf(),
                        source,
                    })?
                    .display()
                    .to_string(),
            )
        } else {
            None
        };
        entries.push(sloppkg_types::ManifestEntry {
            path: manifest_path,
            file_type,
            mode: metadata.permissions().mode(),
            size,
            sha256,
            link_target,
            config_file: false,
        });
    }

    entries.sort_by(|left, right| left.path.cmp(&right.path));

    Ok(PackageManifest {
        package_name: package.package.name.clone(),
        version: package.package.evr.to_string(),
        entries,
    })
}

fn build_package_info(package: &PackageRecord) -> BinaryPackageInfo {
    BinaryPackageInfo {
        package_name: package.package.name.clone(),
        epoch: package.package.evr.epoch,
        version: package.package.evr.version.clone(),
        release: package.package.evr.release.clone(),
        arch: package
            .package
            .architectures
            .first()
            .cloned()
            .unwrap_or_else(|| String::from("any")),
        repo_name: package.repo_name.clone(),
        source_path: package.source_path.display().to_string(),
        summary: package.package.summary.clone(),
        description: package.package.description.clone(),
        license: package.package.license.clone(),
        homepage: package.package.homepage.clone(),
        owned_prefixes: package.install.owned_prefixes.clone(),
        dependencies: package
            .dependencies
            .iter()
            .map(|dependency| BinaryDependency {
                name: dependency.name.clone(),
                constraint: dependency.constraint.to_string(),
                kind: dependency.kind,
                reason: dependency.reason.clone(),
                feature: dependency.feature.clone(),
            })
            .collect(),
        dependency_groups: package
            .dependency_groups
            .iter()
            .map(|group| BinaryDependencyGroup {
                kind: group.kind,
                one_of: group
                    .one_of
                    .iter()
                    .map(|dependency| BinaryDependency {
                        name: dependency.name.clone(),
                        constraint: dependency.constraint.to_string(),
                        kind: dependency.kind,
                        reason: dependency.reason.clone(),
                        feature: dependency.feature.clone(),
                    })
                    .collect(),
            })
            .collect(),
        provides: package
            .provides
            .iter()
            .map(|capability| BinaryCapability {
                name: capability.name.clone(),
                constraint: capability.constraint.to_string(),
            })
            .collect(),
        conflicts: package
            .conflicts
            .iter()
            .map(|capability| BinaryCapability {
                name: capability.name.clone(),
                constraint: capability.constraint.to_string(),
            })
            .collect(),
        replaces: package
            .replaces
            .iter()
            .map(|capability| BinaryCapability {
                name: capability.name.clone(),
                constraint: capability.constraint.to_string(),
            })
            .collect(),
    }
}

fn emit_binary_package(
    package: &PackageRecord,
    package_cache_root: &Path,
    stage_root: &Path,
) -> Result<PathBuf, BuildError> {
    let arch = package
        .package
        .architectures
        .first()
        .cloned()
        .unwrap_or_else(|| String::from("any"));
    let package_dir = package_cache_root.join(&package.package.name);
    fs::create_dir_all(&package_dir).map_err(|source| BuildError::Io {
        path: package_dir.clone(),
        source,
    })?;

    let file_name = format!(
        "{}-{}-{}-{}.sloppkg.tar.zst",
        package.package.name, package.package.evr.version, package.package.evr.release, arch
    );
    let tar_path = stage_root.join(format!("{}-payload.tar", package.package.name));
    let archive_path = package_dir.join(file_name);

    run_command(
        Command::new("tar")
            .arg("-cf")
            .arg(&tar_path)
            .arg("-C")
            .arg(stage_root)
            .arg("pkg-info.toml")
            .arg("manifest.json")
            .arg("root"),
        stage_root,
        format!("tar archive for {}", package.package.name),
    )?;

    compress_file(&tar_path, &archive_path)?;

    fs::remove_file(&tar_path).map_err(|source| BuildError::Io {
        path: tar_path,
        source,
    })?;

    Ok(archive_path)
}

fn compress_file(source: &Path, destination: &Path) -> Result<(), BuildError> {
    let mut input = File::open(source).map_err(|source_err| BuildError::Io {
        path: source.to_path_buf(),
        source: source_err,
    })?;
    let output = File::create(destination).map_err(|source_err| BuildError::Io {
        path: destination.to_path_buf(),
        source: source_err,
    })?;
    let mut encoder = zstd::Encoder::new(output, 19).map_err(|source_err| BuildError::Io {
        path: destination.to_path_buf(),
        source: source_err,
    })?;
    std::io::copy(&mut input, &mut encoder).map_err(|source_err| BuildError::Io {
        path: destination.to_path_buf(),
        source: source_err,
    })?;
    encoder.finish().map_err(|source_err| BuildError::Io {
        path: destination.to_path_buf(),
        source: source_err,
    })?;
    Ok(())
}

fn hash_file(path: &Path) -> Result<String, BuildError> {
    let mut file = File::open(path).map_err(|source| BuildError::Io {
        path: path.to_path_buf(),
        source,
    })?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 8192];
    loop {
        let read = file.read(&mut buffer).map_err(|source| BuildError::Io {
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

fn extract_archive(
    archive: &Path,
    destination: &Path,
    strip_components: usize,
) -> Result<(), BuildError> {
    let mut command = Command::new("tar");
    command.arg("-xf").arg(archive).arg("-C").arg(destination);
    if strip_components > 0 {
        command.arg(format!("--strip-components={strip_components}"));
    }
    let status = command.status().map_err(|source| BuildError::Io {
        path: archive.to_path_buf(),
        source,
    })?;
    if !status.success() {
        return Err(BuildError::CommandFailed {
            cwd: destination.to_path_buf(),
            command: format!("tar -xf {} -C {}", archive.display(), destination.display()),
        });
    }
    Ok(())
}

fn run_command(command: &mut Command, cwd: &Path, label: String) -> Result<(), BuildError> {
    let status = command.status().map_err(|source| BuildError::Io {
        path: cwd.to_path_buf(),
        source,
    })?;
    if !status.success() {
        return Err(BuildError::CommandFailed {
            cwd: cwd.to_path_buf(),
            command: label,
        });
    }
    Ok(())
}

fn copy_path(source: &Path, destination: &Path) -> Result<(), BuildError> {
    if source.is_dir() {
        copy_dir_recursive(source, destination)
    } else {
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent).map_err(|source_err| BuildError::Io {
                path: parent.to_path_buf(),
                source: source_err,
            })?;
        }
        fs::copy(source, destination).map_err(|source_err| BuildError::Io {
            path: destination.to_path_buf(),
            source: source_err,
        })?;
        Ok(())
    }
}

fn copy_dir_contents(source: &Path, destination: &Path) -> Result<(), BuildError> {
    for entry in fs::read_dir(source).map_err(|source_err| BuildError::Io {
        path: source.to_path_buf(),
        source: source_err,
    })? {
        let entry = entry.map_err(|source_err| BuildError::Io {
            path: source.to_path_buf(),
            source: source_err,
        })?;
        let path = entry.path();
        if path.file_name().is_some_and(|name| name == "package.toml") {
            continue;
        }
        let destination_path = destination.join(entry.file_name());
        copy_path(&path, &destination_path)?;
    }
    Ok(())
}

fn copy_dir_recursive(source: &Path, destination: &Path) -> Result<(), BuildError> {
    fs::create_dir_all(destination).map_err(|source_err| BuildError::Io {
        path: destination.to_path_buf(),
        source: source_err,
    })?;

    for entry in WalkDir::new(source) {
        let entry = entry.map_err(|source_err| BuildError::Io {
            path: source.to_path_buf(),
            source: std::io::Error::new(std::io::ErrorKind::Other, source_err),
        })?;
        let relative = entry.path().strip_prefix(source).unwrap_or(entry.path());
        if relative.as_os_str().is_empty() {
            continue;
        }
        let target = destination.join(relative);
        if entry.file_type().is_dir() {
            fs::create_dir_all(&target).map_err(|source_err| BuildError::Io {
                path: target.clone(),
                source: source_err,
            })?;
        } else if entry.file_type().is_file() {
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent).map_err(|source_err| BuildError::Io {
                    path: parent.to_path_buf(),
                    source: source_err,
                })?;
            }
            fs::copy(entry.path(), &target).map_err(|source_err| BuildError::Io {
                path: target.clone(),
                source: source_err,
            })?;
            let mode = fs::metadata(entry.path())
                .map_err(|source_err| BuildError::Io {
                    path: entry.path().to_path_buf(),
                    source: source_err,
                })?
                .permissions()
                .mode();
            fs::set_permissions(&target, fs::Permissions::from_mode(mode)).map_err(
                |source_err| BuildError::Io {
                    path: target.clone(),
                    source: source_err,
                },
            )?;
        }
    }

    Ok(())
}

fn sanitize(input: &str) -> String {
    input
        .chars()
        .map(|ch| if ch.is_ascii_alphanumeric() { ch } else { '-' })
        .collect()
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    use sloppkg_types::{BuildSpec, InstallSpec, PackageMeta, PackageRecord};

    use super::stage_package;

    #[test]
    fn stages_local_file_source_and_manifest() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("sloppkg-build-test-{unique}"));
        let recipe_dir = root.join("recipe");
        let payload_dir = recipe_dir.join("payload");
        let distfiles_dir = root.join("distfiles");
        let build_root = root.join("build");
        std::fs::create_dir_all(&payload_dir).unwrap();
        std::fs::create_dir_all(&distfiles_dir).unwrap();
        std::fs::write(payload_dir.join("hello.sh"), "#!/bin/sh\necho hello\n").unwrap();

        let package = PackageRecord {
            repo_name: String::from("workspace"),
            repo_priority: 50,
            recipe_path: recipe_dir.join("package.toml"),
            source_path: PathBuf::from("hello-stage/0.1.0-1/package.toml"),
            package: PackageMeta {
                name: String::from("hello-stage"),
                evr: sloppkg_types::Evr::parse("0.1.0-1").unwrap(),
                summary: String::from("hello"),
                description: String::from("hello"),
                license: String::from("MIT"),
                homepage: None,
                architectures: vec![String::from("aarch64")],
            },
            sources: vec![sloppkg_types::SourceSpec {
                kind: String::from("file"),
                url: String::from("payload"),
                sha256: String::from("local"),
                filename: None,
                strip_components: 0,
                destination: Some(String::from("payload")),
            }],
            build: BuildSpec {
                system: String::from("custom"),
                out_of_tree: true,
                directory: Some(String::from("payload")),
                env: vec![(String::from("HELLO_TARGET"), String::from("hello-from-env"))],
                configure: Vec::new(),
                build: Vec::new(),
                install: vec![String::from("mkdir -p \"$PKG_DESTDIR/usr/local/bin\" && install -m 0755 \"$PKG_SOURCE_DIR/hello.sh\" \"$PKG_DESTDIR/usr/local/bin/hello-stage\" && printf '%s\\n' \"$HELLO_TARGET\" > \"$PKG_DESTDIR/usr/local/share-target.txt\"")],
                jobs: 1,
            },
            install: InstallSpec {
                prefix: String::from("/usr/local"),
                sysconfdir: String::from("/usr/local/etc"),
                localstatedir: String::from("/usr/local/var"),
                owned_prefixes: vec![String::from("/usr/local")],
                strip_binaries: false,
            },
            dependencies: Vec::new(),
            dependency_groups: Vec::new(),
            provides: Vec::new(),
            conflicts: Vec::new(),
            replaces: Vec::new(),
            bootstrap: None,
        };

        let package_cache_root = root.join("packages");
        std::fs::create_dir_all(&package_cache_root).unwrap();

        let report = stage_package(
            &package,
            &distfiles_dir,
            &build_root,
            &package_cache_root,
            1,
            &[],
        )
        .unwrap();
        assert!(report.manifest_path.exists());
        let manifest = std::fs::read_to_string(&report.manifest_path).unwrap();
        assert!(manifest.contains("/usr/local/bin/hello-stage"));
        assert!(manifest.contains("/usr/local/share-target.txt"));
        assert!(report.package_info_path.exists());
        assert!(report.package_archive_path.exists());
        let marker =
            std::fs::read_to_string(report.destdir.join("usr/local/share-target.txt")).unwrap();
        assert_eq!(marker, "hello-from-env\n");

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn stage_env_overrides_package_env() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("sloppkg-build-override-test-{unique}"));
        let recipe_dir = root.join("recipe");
        let payload_dir = recipe_dir.join("payload");
        let distfiles_dir = root.join("distfiles");
        let build_root = root.join("build");
        std::fs::create_dir_all(&payload_dir).unwrap();
        std::fs::create_dir_all(&distfiles_dir).unwrap();
        std::fs::write(payload_dir.join("install.sh"), "#!/bin/sh\nmkdir -p \"$PKG_DESTDIR/usr/local\"\nprintf '%s\\n' \"$OVERRIDE_ME\" > \"$PKG_DESTDIR/usr/local/override.txt\"\n").unwrap();

        let package = PackageRecord {
            repo_name: String::from("workspace"),
            repo_priority: 50,
            recipe_path: recipe_dir.join("package.toml"),
            source_path: PathBuf::from("override/0.1.0-1/package.toml"),
            package: PackageMeta {
                name: String::from("override"),
                evr: sloppkg_types::Evr::parse("0.1.0-1").unwrap(),
                summary: String::from("override"),
                description: String::from("override"),
                license: String::from("MIT"),
                homepage: None,
                architectures: vec![String::from("aarch64")],
            },
            sources: vec![sloppkg_types::SourceSpec {
                kind: String::from("file"),
                url: String::from("payload"),
                sha256: String::from("local"),
                filename: None,
                strip_components: 0,
                destination: Some(String::from("payload")),
            }],
            build: BuildSpec {
                system: String::from("custom"),
                out_of_tree: true,
                directory: Some(String::from("payload")),
                env: vec![(String::from("OVERRIDE_ME"), String::from("package"))],
                configure: Vec::new(),
                build: Vec::new(),
                install: vec![String::from("sh \"$PKG_SOURCE_DIR/install.sh\"")],
                jobs: 1,
            },
            install: InstallSpec {
                prefix: String::from("/usr/local"),
                sysconfdir: String::from("/usr/local/etc"),
                localstatedir: String::from("/usr/local/var"),
                owned_prefixes: vec![String::from("/usr/local")],
                strip_binaries: false,
            },
            dependencies: Vec::new(),
            dependency_groups: Vec::new(),
            provides: Vec::new(),
            conflicts: Vec::new(),
            replaces: Vec::new(),
            bootstrap: None,
        };

        let package_cache_root = root.join("packages");
        std::fs::create_dir_all(&package_cache_root).unwrap();

        let report = stage_package(
            &package,
            &distfiles_dir,
            &build_root,
            &package_cache_root,
            2,
            &[(String::from("OVERRIDE_ME"), String::from("stage"))],
        )
        .unwrap();

        let marker =
            std::fs::read_to_string(report.destdir.join("usr/local/override.txt")).unwrap();
        assert_eq!(marker, "stage\n");

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn stage_build_includes_managed_prefixes_on_path() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("sloppkg-build-path-test-{unique}"));
        let recipe_dir = root.join("recipe");
        let payload_dir = recipe_dir.join("payload");
        let distfiles_dir = root.join("distfiles");
        let build_root = root.join("build");
        std::fs::create_dir_all(&payload_dir).unwrap();
        std::fs::create_dir_all(&distfiles_dir).unwrap();
        std::fs::write(
            payload_dir.join("capture-path.sh"),
            "#!/bin/sh\nmkdir -p \"$PKG_DESTDIR/usr/local/share\"\nprintf '%s\\n' \"$PATH\" > \"$PKG_DESTDIR/usr/local/share/path.txt\"\n",
        )
        .unwrap();

        let package = PackageRecord {
            repo_name: String::from("workspace"),
            repo_priority: 50,
            recipe_path: recipe_dir.join("package.toml"),
            source_path: PathBuf::from("path-capture/0.1.0-1/package.toml"),
            package: PackageMeta {
                name: String::from("path-capture"),
                evr: sloppkg_types::Evr::parse("0.1.0-1").unwrap(),
                summary: String::from("path capture"),
                description: String::from("path capture"),
                license: String::from("MIT"),
                homepage: None,
                architectures: vec![String::from("aarch64")],
            },
            sources: vec![sloppkg_types::SourceSpec {
                kind: String::from("file"),
                url: String::from("payload"),
                sha256: String::from("local"),
                filename: None,
                strip_components: 0,
                destination: Some(String::from("payload")),
            }],
            build: BuildSpec {
                system: String::from("custom"),
                out_of_tree: true,
                directory: Some(String::from("payload")),
                env: Vec::new(),
                configure: Vec::new(),
                build: Vec::new(),
                install: vec![String::from("sh \"$PKG_SOURCE_DIR/capture-path.sh\"")],
                jobs: 1,
            },
            install: InstallSpec {
                prefix: String::from("/usr/local"),
                sysconfdir: String::from("/usr/local/etc"),
                localstatedir: String::from("/usr/local/var"),
                owned_prefixes: vec![String::from("/usr/local")],
                strip_binaries: false,
            },
            dependencies: Vec::new(),
            dependency_groups: Vec::new(),
            provides: Vec::new(),
            conflicts: Vec::new(),
            replaces: Vec::new(),
            bootstrap: None,
        };

        let package_cache_root = root.join("packages");
        std::fs::create_dir_all(&package_cache_root).unwrap();

        let report = stage_package(
            &package,
            &distfiles_dir,
            &build_root,
            &package_cache_root,
            1,
            &[],
        )
        .unwrap();
        let path_value = std::fs::read_to_string(report.destdir.join("usr/local/share/path.txt"))
            .unwrap();
        assert!(path_value.starts_with(
            "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        ));

        let _ = std::fs::remove_dir_all(root);
    }
}
