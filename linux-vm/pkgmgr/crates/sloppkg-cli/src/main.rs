use std::env;
use std::path::PathBuf;

use clap::{Args, Parser, Subcommand, ValueEnum};
use sloppkg_core::{App, AppPaths, CleanupTarget, RepoSummary};
use sloppkg_types::{RepoConfigEntry, RepoKind, RepoSyncStrategy, RepoTrustMode};

#[derive(Parser, Debug)]
#[command(name = "sloppkg")]
#[command(about = "slopOS package manager prototype")]
struct Cli {
    #[arg(long, global = true, env = "SLOPPKG_STATE_ROOT")]
    state_root: Option<PathBuf>,
    #[arg(long, global = true, env = "SLOPPKG_RECIPE_ROOT")]
    recipe_root: Option<PathBuf>,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    Init,
    Doctor,
    Update(UpdateArgs),
    Cleanup(CleanupArgs),
    Fetch(FetchArgs),
    Resolve(ResolveArgs),
    Build(BuildArgs),
    Install(InstallArgs),
    Upgrade(UpgradeArgs),
    Remove(RemoveArgs),
    Repo {
        #[command(subcommand)]
        command: RepoCommand,
    },
}

#[derive(Args, Debug)]
struct ResolveArgs {
    package: String,
    #[arg(long, default_value = "*")]
    constraint: String,
    #[arg(long)]
    json: bool,
}

#[derive(Args, Debug)]
struct UpdateArgs {
    #[arg(long)]
    name: Option<String>,
    #[arg(long)]
    json: bool,
}

#[derive(Args, Debug)]
struct CleanupArgs {
    #[arg(value_enum, default_value_t = CleanupTargetArg::All)]
    target: CleanupTargetArg,
    #[arg(long)]
    json: bool,
}

#[derive(Args, Debug)]
struct FetchArgs {
    package: String,
    #[arg(long, default_value = "*")]
    constraint: String,
    #[arg(long)]
    json: bool,
}

#[derive(Args, Debug)]
struct BuildArgs {
    package: String,
    #[arg(long, default_value = "*")]
    constraint: String,
    #[arg(long)]
    json: bool,
}

#[derive(Args, Debug)]
struct InstallArgs {
    package: String,
    #[arg(long, default_value = "*")]
    constraint: String,
    #[arg(long, default_value = "/")]
    root: PathBuf,
    #[arg(long)]
    json: bool,
}

#[derive(Args, Debug)]
struct UpgradeArgs {
    #[arg(long, default_value = "/")]
    root: PathBuf,
    #[arg(long)]
    json: bool,
}

#[derive(Args, Debug)]
struct RemoveArgs {
    package: String,
    #[arg(long, default_value = "/")]
    root: PathBuf,
    #[arg(long)]
    json: bool,
}

#[derive(Subcommand, Debug)]
enum RepoCommand {
    List,
    Add(RepoAddArgs),
    Export(RepoExportArgs),
    Publish(RepoPublishArgs),
    Index(RepoIndexArgs),
}

#[derive(Args, Debug)]
struct RepoAddArgs {
    #[arg(long)]
    name: String,
    #[arg(long)]
    url: String,
    #[arg(long)]
    channel: Option<String>,
    #[arg(long, default_value_t = 50)]
    priority: i32,
    #[arg(long, value_enum, default_value_t = RepoKindArg::Recipe)]
    kind: RepoKindArg,
    #[arg(long, value_enum)]
    trust_policy: Option<RepoTrustModeArg>,
    #[arg(long, value_enum)]
    sync_strategy: Option<RepoSyncStrategyArg>,
}

#[derive(Args, Debug)]
struct RepoIndexArgs {
    #[arg(long)]
    name: Option<String>,
    #[arg(long)]
    json: bool,
}

#[derive(Args, Debug)]
struct RepoExportArgs {
    #[arg(long)]
    output: PathBuf,
    #[arg(long, default_value = "stable")]
    channel: String,
    #[arg(long)]
    revision: Option<String>,
    #[arg(long)]
    json: bool,
}

#[derive(Args, Debug)]
struct RepoPublishArgs {
    #[arg(long)]
    name: Option<String>,
    #[arg(long, default_value = "stable")]
    channel: String,
    #[arg(long)]
    revision: Option<String>,
    #[arg(long, default_value_t = 1)]
    keep_revisions: usize,
    #[arg(long)]
    json: bool,
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum RepoKindArg {
    Recipe,
    Binary,
    Unified,
}

impl From<RepoKindArg> for RepoKind {
    fn from(value: RepoKindArg) -> Self {
        match value {
            RepoKindArg::Recipe => RepoKind::Recipe,
            RepoKindArg::Binary => RepoKind::Binary,
            RepoKindArg::Unified => RepoKind::Unified,
        }
    }
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum RepoTrustModeArg {
    Local,
    DigestPinned,
}

impl From<RepoTrustModeArg> for RepoTrustMode {
    fn from(value: RepoTrustModeArg) -> Self {
        match value {
            RepoTrustModeArg::Local => RepoTrustMode::Local,
            RepoTrustModeArg::DigestPinned => RepoTrustMode::DigestPinned,
        }
    }
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum RepoSyncStrategyArg {
    File,
    StaticHttp,
}

impl From<RepoSyncStrategyArg> for RepoSyncStrategy {
    fn from(value: RepoSyncStrategyArg) -> Self {
        match value {
            RepoSyncStrategyArg::File => RepoSyncStrategy::File,
            RepoSyncStrategyArg::StaticHttp => RepoSyncStrategy::StaticHttp,
        }
    }
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum CleanupTargetArg {
    Builds,
    Repos,
    Published,
    All,
}

impl From<CleanupTargetArg> for CleanupTarget {
    fn from(value: CleanupTargetArg) -> Self {
        match value {
            CleanupTargetArg::Builds => CleanupTarget::Builds,
            CleanupTargetArg::Repos => CleanupTarget::Repos,
            CleanupTargetArg::Published => CleanupTarget::Published,
            CleanupTargetArg::All => CleanupTarget::All,
        }
    }
}

fn main() {
    if let Err(err) = run() {
        eprintln!("error: {err}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let cli = Cli::parse();
    let recipe_root = cli.recipe_root.or_else(detect_workspace_recipe_root);
    let state_root = cli
        .state_root
        .unwrap_or_else(|| PathBuf::from("/Volumes/slopos-data/pkg"));
    let app = App::new(AppPaths::from_state_root(state_root));

    match cli.command {
        Command::Init => {
            app.init(recipe_root.as_deref())?;
            println!(
                "initialized sloppkg state at {}",
                app.paths.state_root.display()
            );
        }
        Command::Doctor => {
            let report = app.doctor(recipe_root.as_deref())?;
            println!("status: {}", report.status);
            println!("state_root: {}", report.state_root.display());
            println!("database: {}", report.database_path.display());
            println!("repos: {}", report.repo_count);
            println!("packages: {}", report.packages_loaded);
        }
        Command::Update(args) => {
            let report = app.update(recipe_root.as_deref(), args.name.as_deref())?;
            if args.json {
                println!("{}", serde_json::to_string_pretty(&report)?);
            } else if report.repos.is_empty() {
                println!("no repositories updated");
            } else {
                print!("{}", App::format_update_report(&report));
            }
        }
        Command::Cleanup(args) => {
            let report = app.cleanup(args.target.into())?;
            if args.json {
                println!("{}", serde_json::to_string_pretty(&report)?);
            } else {
                print!("{}", App::format_cleanup_report(&report));
            }
        }
        Command::Fetch(args) => {
            let report = app.fetch(recipe_root.as_deref(), &args.package, &args.constraint)?;
            if args.json {
                println!("{}", serde_json::to_string_pretty(&report)?);
            } else {
                print!("{}", App::format_fetch_report(&report));
            }
        }
        Command::Resolve(args) => {
            let plan = app.resolve(recipe_root.as_deref(), &args.package, &args.constraint)?;
            if args.json {
                println!("{}", serde_json::to_string_pretty(&plan_to_json(&plan))?);
            } else {
                print!("{}", App::format_plan(&plan));
            }
        }
        Command::Build(args) => {
            let report = app.build(recipe_root.as_deref(), &args.package, &args.constraint)?;
            if args.json {
                println!("{}", serde_json::to_string_pretty(&report)?);
            } else {
                print!("{}", App::format_build_report(&report));
            }
        }
        Command::Install(args) => {
            let report = app.install(
                recipe_root.as_deref(),
                &args.package,
                &args.constraint,
                &args.root,
            )?;
            if args.json {
                println!("{}", serde_json::to_string_pretty(&report)?);
            } else {
                print!("{}", App::format_transaction_report(&report));
            }
        }
        Command::Upgrade(args) => {
            let report = app.upgrade(recipe_root.as_deref(), &args.root)?;
            if args.json {
                println!("{}", serde_json::to_string_pretty(&report)?);
            } else {
                print!("{}", App::format_transaction_report(&report));
            }
        }
        Command::Remove(args) => {
            let report = app.remove(&args.package, &args.root)?;
            if args.json {
                println!("{}", serde_json::to_string_pretty(&report)?);
            } else {
                print!("{}", App::format_transaction_report(&report));
            }
        }
        Command::Repo {
            command: RepoCommand::List,
        } => {
            let repos = app.list_repos(recipe_root.as_deref())?;
            if repos.is_empty() {
                println!("no repositories configured");
            } else {
                print_repos(&repos);
            }
        }
        Command::Repo {
            command: RepoCommand::Add(args),
        } => {
            let kind: RepoKind = args.kind.into();
            let channel = match kind {
                RepoKind::Unified => Some(args.channel.unwrap_or_else(|| String::from("stable"))),
                _ => args.channel,
            };
            app.add_repo(RepoConfigEntry {
                name: args.name,
                kind,
                url: args.url,
                channel,
                priority: args.priority,
                enabled: true,
                trust_policy: args
                    .trust_policy
                    .map(Into::into)
                    .unwrap_or(default_trust_policy(kind)),
                sync_strategy: args
                    .sync_strategy
                    .map(Into::into)
                    .unwrap_or(default_sync_strategy(kind)),
            })?;
            println!("repository added");
        }
        Command::Repo {
            command: RepoCommand::Index(args),
        } => {
            let report = app.index_binary_repo(args.name.as_deref())?;
            if args.json {
                println!("{}", serde_json::to_string_pretty(&report)?);
            } else {
                print!("{}", App::format_repo_index_report(&report));
            }
        }
        Command::Repo {
            command: RepoCommand::Export(args),
        } => {
            let report = app.export_repo(
                recipe_root.as_deref(),
                &args.output,
                &args.channel,
                args.revision.as_deref(),
            )?;
            if args.json {
                println!("{}", serde_json::to_string_pretty(&report)?);
            } else {
                print!("{}", App::format_repo_export_report(&report));
            }
        }
        Command::Repo {
            command: RepoCommand::Publish(args),
        } => {
            let report = app.publish_repo(
                recipe_root.as_deref(),
                args.name.as_deref(),
                &args.channel,
                args.revision.as_deref(),
                args.keep_revisions,
            )?;
            if args.json {
                println!("{}", serde_json::to_string_pretty(&report)?);
            } else {
                print!("{}", App::format_repo_publish_report(&report));
            }
        }
    }

    Ok(())
}

fn detect_workspace_recipe_root() -> Option<PathBuf> {
    let current = env::current_dir().ok()?;
    for base in current.ancestors() {
        let direct = base.join("packages/repo.toml");
        if direct.exists() {
            return Some(base.join("packages"));
        }

        let nested = base.join("linux-vm/packages/repo.toml");
        if nested.exists() {
            return Some(base.join("linux-vm/packages"));
        }
    }
    None
}

fn print_repos(repos: &[RepoSummary]) {
    for repo in repos {
        println!(
            "- {} [{}] priority={} enabled={} trust={} sync={}{} url={}",
            repo.name,
            repo.kind,
            repo.priority,
            repo.enabled,
            repo.trust_policy,
            repo.sync_strategy,
            repo.channel
                .as_deref()
                .map(|channel| format!(" channel={channel}"))
                .unwrap_or_default(),
            repo.url
        );
    }
}

const fn default_trust_policy(kind: RepoKind) -> RepoTrustMode {
    match kind {
        RepoKind::Recipe | RepoKind::Binary => RepoTrustMode::Local,
        RepoKind::Unified => RepoTrustMode::DigestPinned,
    }
}

const fn default_sync_strategy(kind: RepoKind) -> RepoSyncStrategy {
    match kind {
        RepoKind::Recipe | RepoKind::Binary => RepoSyncStrategy::File,
        RepoKind::Unified => RepoSyncStrategy::StaticHttp,
    }
}

fn plan_to_json(plan: &sloppkg_types::TransactionPlan) -> serde_json::Value {
    serde_json::json!({
        "requested": plan.requested.iter().map(|request| {
            serde_json::json!({
                "name": request.name,
                "constraint": request.constraint.to_string(),
            })
        }).collect::<Vec<_>>(),
        "packages": plan.packages.iter().map(|package| {
            serde_json::json!({
                "name": package.package.package.name,
                "version": package.package.package.evr.to_string(),
                "repo": package.package.repo_name,
                "reason": package.reason,
                "source_path": package.package.source_path.display().to_string(),
            })
        }).collect::<Vec<_>>()
    })
}
