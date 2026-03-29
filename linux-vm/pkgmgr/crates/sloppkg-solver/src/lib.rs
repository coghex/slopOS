use std::collections::{BTreeMap, BTreeSet};

use sloppkg_types::{
    Capability, Dependency, DependencyGroup, DependencyKind, PackageRecord, PlannedPackage,
    RequestedPackage, TransactionPlan,
};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum SolveError {
    #[error("no candidate satisfies {requirement} ({chain})")]
    Unsatisfied { requirement: String, chain: String },
    #[error("conflict while selecting {candidate}: {reason}")]
    Conflict { candidate: String, reason: String },
}

#[derive(Clone, Debug, Default)]
pub struct SolveOptions {
    pub include_build_dependencies: bool,
    pub include_optional_dependencies: bool,
}

pub fn resolve(
    packages: &[PackageRecord],
    requests: &[RequestedPackage],
    options: &SolveOptions,
) -> Result<TransactionPlan, SolveError> {
    let mut resolver = Resolver {
        packages,
        options,
        selected: BTreeMap::new(),
        order: Vec::new(),
    };

    for request in requests {
        resolver.resolve_request(request.clone(), vec![request.name.clone()])?;
    }

    let mut planned = Vec::new();
    let mut seen = BTreeSet::new();
    for key in resolver.order {
        if seen.insert(key.clone()) {
            if let Some(package) = resolver.selected.remove(&key) {
                planned.push(package);
            }
        }
    }

    Ok(TransactionPlan {
        requested: requests.to_vec(),
        packages: planned,
    })
}

struct Resolver<'a> {
    packages: &'a [PackageRecord],
    options: &'a SolveOptions,
    selected: BTreeMap<String, PlannedPackage>,
    order: Vec<String>,
}

impl<'a> Resolver<'a> {
    fn resolve_request(
        &mut self,
        request: RequestedPackage,
        chain: Vec<String>,
    ) -> Result<(), SolveError> {
        let dependency = Dependency {
            name: request.name.clone(),
            constraint: request.constraint.clone(),
            kind: DependencyKind::Runtime,
            reason: None,
            feature: None,
        };
        let candidate = self.select_candidate(&dependency, &chain)?;
        self.select_package(
            candidate,
            format!("requested by {} {}", request.name, request.constraint),
            chain,
        )
    }

    fn select_package(
        &mut self,
        candidate: PackageRecord,
        reason: String,
        chain: Vec<String>,
    ) -> Result<(), SolveError> {
        let key = package_key(&candidate);
        if self.selected.contains_key(&key) {
            return Ok(());
        }

        if let Some(existing) = self
            .selected
            .values()
            .find(|existing| existing.package.package.name == candidate.package.name)
        {
            if existing.package.package.evr == candidate.package.evr {
                return Ok(());
            }
            return Err(SolveError::Conflict {
                candidate: format_package(&candidate),
                reason: format!(
                    "package {} is already selected at {}",
                    existing.package.package.name, existing.package.package.evr
                ),
            });
        }

        self.ensure_no_conflicts(&candidate)?;

        self.selected.insert(
            key.clone(),
            PlannedPackage {
                package: candidate.clone(),
                reason,
            },
        );

        let dependencies = candidate
            .dependencies
            .iter()
            .filter(|dep| self.should_include(dep.kind))
            .cloned()
            .collect::<Vec<_>>();

        for dependency in dependencies {
            let mut next_chain = chain.clone();
            next_chain.push(dependency.name.clone());
            let resolved = self.select_candidate(&dependency, &next_chain)?;
            self.select_package(
                resolved,
                format!(
                    "dependency {} {} of {}",
                    dependency.name, dependency.constraint, candidate.package.name
                ),
                next_chain,
            )?;
        }

        let dependency_groups = candidate
            .dependency_groups
            .iter()
            .filter(|group| self.should_include(group.kind))
            .cloned()
            .collect::<Vec<_>>();

        for group in dependency_groups {
            self.resolve_group(&candidate, group, chain.clone())?;
        }

        self.order.push(key);
        Ok(())
    }

    fn resolve_group(
        &mut self,
        dependent: &PackageRecord,
        group: DependencyGroup,
        chain: Vec<String>,
    ) -> Result<(), SolveError> {
        let mut last_error = None;
        for dependency in group.one_of {
            let mut next_chain = chain.clone();
            next_chain.push(dependency.name.clone());
            match self
                .select_candidate(&dependency, &next_chain)
                .and_then(|candidate| {
                    self.select_package(
                        candidate,
                        format!(
                            "dependency group choice {} {} of {}",
                            dependency.name, dependency.constraint, dependent.package.name
                        ),
                        next_chain,
                    )
                }) {
                Ok(()) => return Ok(()),
                Err(err) => last_error = Some(err),
            }
        }

        Err(last_error.unwrap_or(SolveError::Unsatisfied {
            requirement: format!("dependency group for {}", dependent.package.name),
            chain: chain.join(" -> "),
        }))
    }

    fn select_candidate(
        &self,
        dependency: &Dependency,
        chain: &[String],
    ) -> Result<PackageRecord, SolveError> {
        let mut candidates = self
            .packages
            .iter()
            .filter(|package| is_arch_compatible(package))
            .filter(|package| package_matches(package, dependency))
            .cloned()
            .collect::<Vec<_>>();

        candidates.sort_by(|left, right| {
            rank(left, dependency)
                .cmp(&rank(right, dependency))
                .reverse()
        });

        candidates
            .into_iter()
            .find(|candidate| !self.conflicts_with_selected(candidate))
            .ok_or_else(|| SolveError::Unsatisfied {
                requirement: format!("{} {}", dependency.name, dependency.constraint),
                chain: chain.join(" -> "),
            })
    }

    fn ensure_no_conflicts(&self, candidate: &PackageRecord) -> Result<(), SolveError> {
        if let Some(conflict) = self.selected.values().find(|selected| {
            package_conflicts(candidate, &selected.package)
                || package_conflicts(&selected.package, candidate)
        }) {
            return Err(SolveError::Conflict {
                candidate: format_package(candidate),
                reason: format!("conflicts with {}", format_package(&conflict.package)),
            });
        }

        Ok(())
    }

    fn conflicts_with_selected(&self, candidate: &PackageRecord) -> bool {
        self.selected.values().any(|selected| {
            package_conflicts(candidate, &selected.package)
                || package_conflicts(&selected.package, candidate)
        })
    }

    fn should_include(&self, kind: DependencyKind) -> bool {
        match kind {
            DependencyKind::Runtime => true,
            DependencyKind::Build => self.options.include_build_dependencies,
            DependencyKind::Optional => self.options.include_optional_dependencies,
            DependencyKind::Test => false,
        }
    }
}

fn rank(
    package: &PackageRecord,
    dependency: &Dependency,
) -> (bool, i32, sloppkg_types::Evr, String) {
    (
        package.package.name == dependency.name,
        package.repo_priority,
        package.package.evr.clone(),
        package.package.name.clone(),
    )
}

fn package_key(package: &PackageRecord) -> String {
    format!(
        "{}:{}:{}:{}",
        package.repo_name,
        package.package.name,
        package.package.evr,
        package.package.architectures.join(",")
    )
}

fn format_package(package: &PackageRecord) -> String {
    format!(
        "{} {} [{}]",
        package.package.name, package.package.evr, package.repo_name
    )
}

fn is_arch_compatible(package: &PackageRecord) -> bool {
    package
        .package
        .architectures
        .iter()
        .any(|arch| arch == "aarch64" || arch == "any")
}

fn package_matches(package: &PackageRecord, dependency: &Dependency) -> bool {
    if package.package.name == dependency.name
        && dependency.constraint.matches(&package.package.evr)
    {
        return true;
    }

    package.provides.iter().any(|provide| {
        provide.name == dependency.name
            && provide.constraint.matches(&package.package.evr)
            && dependency.constraint.matches(&package.package.evr)
    })
}

fn package_conflicts(left: &PackageRecord, right: &PackageRecord) -> bool {
    left.conflicts
        .iter()
        .any(|conflict| capability_matches(conflict, right))
}

fn capability_matches(capability: &Capability, package: &PackageRecord) -> bool {
    if capability.name == package.package.name
        && capability.constraint.matches(&package.package.evr)
    {
        return true;
    }

    package.provides.iter().any(|provided| {
        provided.name == capability.name && capability.constraint.matches(&package.package.evr)
    })
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;
    use std::path::PathBuf;

    use sloppkg_types::{
        BuildSpec, Capability, Constraint, Dependency, DependencyGroup, DependencyKind, Evr,
        InstallSpec, PackageMeta, PackageRecord, RequestedPackage,
    };

    use crate::{resolve, SolveOptions};

    fn package(name: &str, version: &str) -> PackageRecord {
        PackageRecord {
            repo_name: String::from("workspace"),
            repo_priority: 50,
            recipe_path: PathBuf::from(format!("/tmp/{name}-{version}/package.toml")),
            source_path: PathBuf::from(format!("packages/{name}/{version}/package.toml")),
            package: PackageMeta {
                name: name.to_owned(),
                evr: Evr::parse(version).unwrap(),
                summary: name.to_owned(),
                description: name.to_owned(),
                license: String::from("MIT"),
                homepage: None,
                architectures: vec![String::from("aarch64")],
            },
            sources: Vec::new(),
            build: BuildSpec {
                system: String::from("gnu"),
                out_of_tree: true,
                directory: None,
                env: Vec::new(),
                configure: Vec::new(),
                build: Vec::new(),
                install: Vec::new(),
                jobs: 0,
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
        }
    }

    #[test]
    fn picks_highest_version_and_dependencies() {
        let zlib_old = package("zlib", "1.3.0-1");
        let zlib_new = package("zlib", "1.3.1-1");
        let mut libpng = package("libpng", "1.6.44-1");
        libpng.dependencies.push(Dependency {
            name: String::from("zlib"),
            constraint: Constraint::parse(">= 1.3.0-1").unwrap(),
            kind: DependencyKind::Runtime,
            reason: None,
            feature: None,
        });

        let plan = resolve(
            &[libpng, zlib_old, zlib_new],
            &[RequestedPackage {
                name: String::from("libpng"),
                constraint: Constraint::Any,
            }],
            &SolveOptions::default(),
        )
        .unwrap();

        let names = plan
            .packages
            .iter()
            .map(|pkg| pkg.package.package.name.as_str())
            .collect::<BTreeSet<_>>();
        assert!(names.contains("libpng"));
        assert!(names.contains("zlib"));
        assert!(plan
            .packages
            .iter()
            .any(|pkg| pkg.package.package.name == "zlib"
                && pkg.package.package.evr == Evr::parse("1.3.1-1").unwrap()));
    }

    #[test]
    fn supports_virtual_providers() {
        let mut openssl = package("openssl", "3.2.2-1");
        openssl.provides.push(Capability {
            name: String::from("tls-provider"),
            constraint: Constraint::parse(">= 1-0").unwrap(),
        });
        let mut curl = package("curl", "8.12.1-1");
        curl.dependencies.push(Dependency {
            name: String::from("tls-provider"),
            constraint: Constraint::parse(">= 1-0").unwrap(),
            kind: DependencyKind::Runtime,
            reason: None,
            feature: None,
        });
        curl.dependency_groups.push(DependencyGroup {
            kind: DependencyKind::Optional,
            one_of: Vec::new(),
        });

        let plan = resolve(
            &[curl, openssl],
            &[RequestedPackage {
                name: String::from("curl"),
                constraint: Constraint::Any,
            }],
            &SolveOptions::default(),
        )
        .unwrap();

        assert!(plan
            .packages
            .iter()
            .any(|pkg| pkg.package.package.name == "openssl"));
    }
}
