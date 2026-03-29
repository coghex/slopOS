use std::fs;
use std::path::{Path, PathBuf};

use rusqlite::{params, Connection};
use sloppkg_types::{BinaryPackageInfo, PackageManifest};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum DbError {
    #[error("failed to create database directory {path}: {source}")]
    CreateDir {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("failed to open sqlite database at {path}: {source}")]
    Open {
        path: PathBuf,
        #[source]
        source: rusqlite::Error,
    },
    #[error("failed to initialize sqlite database: {0}")]
    Sql(#[from] rusqlite::Error),
}

#[derive(Clone, Debug)]
pub struct TransactionActionRecord {
    pub action_kind: String,
    pub package_name: String,
    pub version_text: String,
    pub reason: String,
}

#[derive(Clone, Debug)]
pub struct CachePackageRecord {
    pub name: String,
    pub epoch: u64,
    pub version: String,
    pub release: String,
    pub arch: String,
    pub archive_path: String,
    pub checksum: String,
    pub recipe_hash: Option<String>,
    pub build_transaction_id: i64,
}

#[derive(Clone, Debug)]
pub struct DistfileRecord {
    pub source_url: String,
    pub local_filename: String,
    pub checksum: String,
    pub size: Option<u64>,
    pub fetch_source: Option<String>,
}

#[derive(Clone, Debug)]
pub struct InstalledFileConflict {
    pub path: String,
    pub owner: String,
}

#[derive(Clone, Debug)]
pub struct WorldEntry {
    pub package_name: String,
    pub constraint_text: String,
}

#[derive(Clone, Debug)]
pub struct InstalledPackageRecord {
    pub name: String,
    pub epoch: u64,
    pub version: String,
    pub release: String,
    pub arch: String,
    pub repository: Option<String>,
    pub archive_checksum: Option<String>,
    pub install_reason: String,
    pub state: String,
}

#[derive(Clone, Debug)]
pub struct InstalledDependencyRecord {
    pub package_name: String,
    pub dependency_name: String,
    pub constraint_text: String,
    pub chosen_provider: Option<String>,
}

#[derive(Clone, Debug)]
pub struct TransactionStatusRecord {
    pub transaction_id: i64,
    pub status: String,
}

pub fn initialize(path: &Path) -> Result<(), DbError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|source| DbError::CreateDir {
            path: parent.to_path_buf(),
            source,
        })?;
    }

    let connection = Connection::open(path).map_err(|source| DbError::Open {
        path: path.to_path_buf(),
        source,
    })?;
    connection.pragma_update(None, "journal_mode", "WAL")?;
    connection.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS repo_snapshots (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            checksum TEXT,
            generated_at TEXT,
            cache_path TEXT,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE IF NOT EXISTS world (
            id INTEGER PRIMARY KEY,
            package_name TEXT NOT NULL,
            constraint_text TEXT NOT NULL,
            features TEXT NOT NULL DEFAULT '[]',
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE IF NOT EXISTS pins (
            id INTEGER PRIMARY KEY,
            package_name TEXT NOT NULL,
            constraint_text TEXT NOT NULL,
            reason TEXT
        );
        CREATE TABLE IF NOT EXISTS holds (
            id INTEGER PRIMARY KEY,
            package_name TEXT NOT NULL,
            reason TEXT
        );
        CREATE TABLE IF NOT EXISTS installed_packages (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            epoch INTEGER NOT NULL DEFAULT 0,
            version TEXT NOT NULL,
            release TEXT NOT NULL,
            arch TEXT NOT NULL,
            repository TEXT,
            recipe_hash TEXT,
            archive_checksum TEXT,
            install_reason TEXT NOT NULL,
            state TEXT NOT NULL,
            requested_features TEXT NOT NULL DEFAULT '[]',
            installed_at TEXT DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE IF NOT EXISTS installed_dependencies (
            id INTEGER PRIMARY KEY,
            package_name TEXT NOT NULL,
            dependency_name TEXT NOT NULL,
            constraint_text TEXT NOT NULL,
            chosen_provider TEXT
        );
        CREATE TABLE IF NOT EXISTS installed_provides (
            id INTEGER PRIMARY KEY,
            package_name TEXT NOT NULL,
            provide_name TEXT NOT NULL,
            constraint_text TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS installed_files (
            id INTEGER PRIMARY KEY,
            package_name TEXT NOT NULL,
            path TEXT NOT NULL,
            file_type TEXT NOT NULL,
            digest TEXT,
            mode TEXT,
            size INTEGER,
            config_file INTEGER NOT NULL DEFAULT 0
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_installed_files_path ON installed_files(path);
        CREATE TABLE IF NOT EXISTS transactions (
            id INTEGER PRIMARY KEY,
            status TEXT NOT NULL,
            operation TEXT NOT NULL,
            requested_json TEXT NOT NULL,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP,
            updated_at TEXT DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE IF NOT EXISTS transaction_actions (
            id INTEGER PRIMARY KEY,
            transaction_id INTEGER NOT NULL,
            action_kind TEXT NOT NULL,
            package_name TEXT NOT NULL,
            version_text TEXT NOT NULL,
            reason TEXT NOT NULL,
            FOREIGN KEY(transaction_id) REFERENCES transactions(id)
        );
        CREATE TABLE IF NOT EXISTS cache_packages (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            epoch INTEGER NOT NULL DEFAULT 0,
            version TEXT NOT NULL,
            release TEXT NOT NULL,
            arch TEXT NOT NULL,
            archive_path TEXT NOT NULL,
            checksum TEXT NOT NULL,
            recipe_hash TEXT,
            build_transaction_id INTEGER,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE IF NOT EXISTS distfiles (
            id INTEGER PRIMARY KEY,
            source_url TEXT NOT NULL,
            local_filename TEXT NOT NULL,
            checksum TEXT NOT NULL,
            size INTEGER,
            fetch_source TEXT,
            last_verified_at TEXT
        );
        "#,
    )?;

    Ok(())
}

pub fn check(path: &Path) -> Result<(), DbError> {
    let connection = Connection::open(path).map_err(|source| DbError::Open {
        path: path.to_path_buf(),
        source,
    })?;
    connection.query_row("SELECT 1", [], |_| Ok(()))?;
    Ok(())
}

pub fn create_transaction(
    path: &Path,
    operation: &str,
    requested_json: &str,
    actions: &[TransactionActionRecord],
) -> Result<i64, DbError> {
    let connection = Connection::open(path).map_err(|source| DbError::Open {
        path: path.to_path_buf(),
        source,
    })?;

    connection.execute(
        "INSERT INTO transactions(status, operation, requested_json) VALUES(?1, ?2, ?3)",
        params!["planned", operation, requested_json],
    )?;
    let transaction_id = connection.last_insert_rowid();

    for action in actions {
        connection.execute(
            "INSERT INTO transaction_actions(transaction_id, action_kind, package_name, version_text, reason) VALUES(?1, ?2, ?3, ?4, ?5)",
            params![
                transaction_id,
                action.action_kind,
                action.package_name,
                action.version_text,
                action.reason,
            ],
        )?;
    }

    Ok(transaction_id)
}

pub fn update_transaction_status(
    path: &Path,
    transaction_id: i64,
    status: &str,
) -> Result<(), DbError> {
    let connection = Connection::open(path).map_err(|source| DbError::Open {
        path: path.to_path_buf(),
        source,
    })?;
    connection.execute(
        "UPDATE transactions SET status = ?1, updated_at = CURRENT_TIMESTAMP WHERE id = ?2",
        params![status, transaction_id],
    )?;
    Ok(())
}

pub fn record_cache_package(path: &Path, record: &CachePackageRecord) -> Result<(), DbError> {
    let connection = Connection::open(path).map_err(|source| DbError::Open {
        path: path.to_path_buf(),
        source,
    })?;
    connection.execute(
        "INSERT INTO cache_packages(name, epoch, version, release, arch, archive_path, checksum, recipe_hash, build_transaction_id) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        params![
            record.name,
            record.epoch,
            record.version,
            record.release,
            record.arch,
            record.archive_path,
            record.checksum,
            record.recipe_hash,
            record.build_transaction_id,
        ],
    )?;
    Ok(())
}

pub fn record_distfile(path: &Path, record: &DistfileRecord) -> Result<(), DbError> {
    let connection = Connection::open(path).map_err(|source| DbError::Open {
        path: path.to_path_buf(),
        source,
    })?;
    connection.execute(
        "DELETE FROM distfiles WHERE source_url = ?1 OR local_filename = ?2",
        params![record.source_url, record.local_filename],
    )?;
    connection.execute(
        "INSERT INTO distfiles(source_url, local_filename, checksum, size, fetch_source, last_verified_at) VALUES(?1, ?2, ?3, ?4, ?5, CURRENT_TIMESTAMP)",
        params![
            record.source_url,
            record.local_filename,
            record.checksum,
            record.size.map(|size| size as i64),
            record.fetch_source,
        ],
    )?;
    Ok(())
}

pub fn find_installed_file_conflicts(
    path: &Path,
    package_name: &str,
    install_paths: &[String],
) -> Result<Vec<InstalledFileConflict>, DbError> {
    find_installed_file_conflicts_excluding(path, package_name, install_paths, &[])
}

pub fn find_installed_file_conflicts_excluding(
    path: &Path,
    package_name: &str,
    install_paths: &[String],
    excluded_owners: &[String],
) -> Result<Vec<InstalledFileConflict>, DbError> {
    let connection = Connection::open(path).map_err(|source| DbError::Open {
        path: path.to_path_buf(),
        source,
    })?;
    let mut conflicts = Vec::new();
    let mut statement = connection.prepare(
        "SELECT package_name FROM installed_files WHERE path = ?1 AND package_name != ?2",
    )?;
    for install_path in install_paths {
        let owners = statement.query_map(params![install_path, package_name], |row| {
            row.get::<_, String>(0)
        })?;
        for owner in owners.flatten() {
            if excluded_owners.iter().any(|excluded| excluded == &owner) {
                continue;
            }
            conflicts.push(InstalledFileConflict {
                path: install_path.clone(),
                owner,
            });
            break;
        }
    }
    Ok(conflicts)
}

pub fn record_installed_package(
    path: &Path,
    package: &BinaryPackageInfo,
    manifest: &PackageManifest,
    archive_checksum: &str,
    repository: Option<&str>,
    install_reason: &str,
) -> Result<(), DbError> {
    let mut connection = Connection::open(path).map_err(|source| DbError::Open {
        path: path.to_path_buf(),
        source,
    })?;
    let transaction = connection.transaction()?;

    transaction.execute(
        "DELETE FROM installed_dependencies WHERE package_name = ?1",
        params![package.package_name],
    )?;
    transaction.execute(
        "DELETE FROM installed_provides WHERE package_name = ?1",
        params![package.package_name],
    )?;
    transaction.execute(
        "DELETE FROM installed_files WHERE package_name = ?1",
        params![package.package_name],
    )?;
    transaction.execute(
        "DELETE FROM installed_packages WHERE name = ?1",
        params![package.package_name],
    )?;

    transaction.execute(
        "INSERT INTO installed_packages(name, epoch, version, release, arch, repository, recipe_hash, archive_checksum, install_reason, state, requested_features) VALUES(?1, ?2, ?3, ?4, ?5, ?6, NULL, ?7, ?8, 'installed', '[]')",
        params![
            package.package_name,
            package.epoch,
            package.version,
            package.release,
            package.arch,
            repository.unwrap_or(&package.repo_name),
            archive_checksum,
            install_reason,
        ],
    )?;

    for dependency in &package.dependencies {
        transaction.execute(
            "INSERT INTO installed_dependencies(package_name, dependency_name, constraint_text, chosen_provider) VALUES(?1, ?2, ?3, NULL)",
            params![package.package_name, dependency.name, dependency.constraint],
        )?;
    }

    for capability in &package.provides {
        transaction.execute(
            "INSERT INTO installed_provides(package_name, provide_name, constraint_text) VALUES(?1, ?2, ?3)",
            params![package.package_name, capability.name, capability.constraint],
        )?;
    }

    for entry in manifest
        .entries
        .iter()
        .filter(|entry| entry.file_type != "dir")
    {
        transaction.execute(
            "INSERT INTO installed_files(package_name, path, file_type, digest, mode, size, config_file) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                package.package_name,
                entry.path,
                entry.file_type,
                entry.sha256,
                format!("{:o}", entry.mode),
                entry.size as i64,
                if entry.config_file { 1 } else { 0 },
            ],
        )?;
    }

    transaction.commit()?;
    Ok(())
}

pub fn upsert_world_entry(
    path: &Path,
    package_name: &str,
    constraint_text: &str,
) -> Result<(), DbError> {
    let connection = Connection::open(path).map_err(|source| DbError::Open {
        path: path.to_path_buf(),
        source,
    })?;
    connection.execute(
        "DELETE FROM world WHERE package_name = ?1",
        params![package_name],
    )?;
    connection.execute(
        "INSERT INTO world(package_name, constraint_text, features) VALUES(?1, ?2, '[]')",
        params![package_name, constraint_text],
    )?;
    Ok(())
}

pub fn remove_world_entry(path: &Path, package_name: &str) -> Result<(), DbError> {
    let connection = Connection::open(path).map_err(|source| DbError::Open {
        path: path.to_path_buf(),
        source,
    })?;
    connection.execute(
        "DELETE FROM world WHERE package_name = ?1",
        params![package_name],
    )?;
    Ok(())
}

pub fn list_world_entries(path: &Path) -> Result<Vec<WorldEntry>, DbError> {
    let connection = Connection::open(path).map_err(|source| DbError::Open {
        path: path.to_path_buf(),
        source,
    })?;
    let mut statement = connection
        .prepare("SELECT package_name, constraint_text FROM world ORDER BY package_name")?;
    let rows = statement.query_map([], |row| {
        Ok(WorldEntry {
            package_name: row.get(0)?,
            constraint_text: row.get(1)?,
        })
    })?;
    Ok(rows.flatten().collect())
}

pub fn list_installed_packages(path: &Path) -> Result<Vec<InstalledPackageRecord>, DbError> {
    let connection = Connection::open(path).map_err(|source| DbError::Open {
        path: path.to_path_buf(),
        source,
    })?;
    let mut statement = connection.prepare(
        "SELECT name, epoch, version, release, arch, repository, archive_checksum, install_reason, state FROM installed_packages ORDER BY name",
    )?;
    let rows = statement.query_map([], |row| {
        Ok(InstalledPackageRecord {
            name: row.get(0)?,
            epoch: row.get::<_, u64>(1)?,
            version: row.get(2)?,
            release: row.get(3)?,
            arch: row.get(4)?,
            repository: row.get(5)?,
            archive_checksum: row.get(6)?,
            install_reason: row.get(7)?,
            state: row.get(8)?,
        })
    })?;
    Ok(rows.flatten().collect())
}

pub fn list_installed_dependencies(path: &Path) -> Result<Vec<InstalledDependencyRecord>, DbError> {
    let connection = Connection::open(path).map_err(|source| DbError::Open {
        path: path.to_path_buf(),
        source,
    })?;
    let mut statement = connection.prepare(
        "SELECT package_name, dependency_name, constraint_text, chosen_provider FROM installed_dependencies ORDER BY package_name, dependency_name",
    )?;
    let rows = statement.query_map([], |row| {
        Ok(InstalledDependencyRecord {
            package_name: row.get(0)?,
            dependency_name: row.get(1)?,
            constraint_text: row.get(2)?,
            chosen_provider: row.get(3)?,
        })
    })?;
    Ok(rows.flatten().collect())
}

pub fn list_installed_files_for_package(
    path: &Path,
    package_name: &str,
) -> Result<Vec<String>, DbError> {
    let connection = Connection::open(path).map_err(|source| DbError::Open {
        path: path.to_path_buf(),
        source,
    })?;
    let mut statement = connection
        .prepare("SELECT path FROM installed_files WHERE package_name = ?1 ORDER BY path")?;
    let rows = statement.query_map(params![package_name], |row| row.get::<_, String>(0))?;
    Ok(rows.flatten().collect())
}

pub fn list_transaction_statuses(path: &Path) -> Result<Vec<TransactionStatusRecord>, DbError> {
    let connection = Connection::open(path).map_err(|source| DbError::Open {
        path: path.to_path_buf(),
        source,
    })?;
    let mut statement = connection.prepare("SELECT id, status FROM transactions ORDER BY id")?;
    let rows = statement.query_map([], |row| {
        Ok(TransactionStatusRecord {
            transaction_id: row.get(0)?,
            status: row.get(1)?,
        })
    })?;
    Ok(rows.flatten().collect())
}

pub fn find_cache_packages(
    path: &Path,
    name: &str,
    epoch: u64,
    version: &str,
    release: &str,
    arch: &str,
) -> Result<Vec<CachePackageRecord>, DbError> {
    let connection = Connection::open(path).map_err(|source| DbError::Open {
        path: path.to_path_buf(),
        source,
    })?;
    let mut statement = connection.prepare(
        "SELECT name, epoch, version, release, arch, archive_path, checksum, recipe_hash, build_transaction_id
         FROM cache_packages
         WHERE name = ?1 AND epoch = ?2 AND version = ?3 AND release = ?4 AND arch = ?5
         ORDER BY id DESC",
    )?;
    let rows = statement.query_map(params![name, epoch, version, release, arch], |row| {
        Ok(CachePackageRecord {
            name: row.get(0)?,
            epoch: row.get(1)?,
            version: row.get(2)?,
            release: row.get(3)?,
            arch: row.get(4)?,
            archive_path: row.get(5)?,
            checksum: row.get(6)?,
            recipe_hash: row.get(7)?,
            build_transaction_id: row.get(8)?,
        })
    })?;
    Ok(rows.flatten().collect())
}

pub fn remove_installed_package_records(path: &Path, package_name: &str) -> Result<(), DbError> {
    let mut connection = Connection::open(path).map_err(|source| DbError::Open {
        path: path.to_path_buf(),
        source,
    })?;
    let transaction = connection.transaction()?;
    transaction.execute(
        "DELETE FROM installed_dependencies WHERE package_name = ?1",
        params![package_name],
    )?;
    transaction.execute(
        "DELETE FROM installed_provides WHERE package_name = ?1",
        params![package_name],
    )?;
    transaction.execute(
        "DELETE FROM installed_files WHERE package_name = ?1",
        params![package_name],
    )?;
    transaction.execute(
        "DELETE FROM installed_packages WHERE name = ?1",
        params![package_name],
    )?;
    transaction.commit()?;
    Ok(())
}
