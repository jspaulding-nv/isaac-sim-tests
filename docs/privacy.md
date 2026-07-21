# Privacy and Publication Guide

The scripts write detailed local evidence under `output/`. That directory is
ignored by Git because raw system evidence can contain information that should
not be published without review.

Potentially sensitive fields include:

- Hostnames, usernames, home-directory paths, mount paths, and VM identifiers.
- Private IP addresses, DNS behavior, ports, and network topology.
- GPU UUIDs, PCI addresses, serial numbers, and license information.
- Container names, image registries, environment variables, and orchestration
  metadata.
- Browser chrome, bookmarks, account avatars, notifications, and unrelated
  windows in screenshots or recordings.
- Proprietary scene names, assets, robot models, and workload parameters.

Before publishing generated output:

1. Copy only the minimum files needed to support a result.
2. Search for names, organization/project terms, email addresses, IPs,
   absolute paths, hostnames, UUIDs, tokens, passwords, and private URLs.
3. Replace identifiers consistently with neutral labels.
4. Inspect images frame by frame and crop or redact browser chrome.
5. Run a secret scanner and inspect the complete staged Git diff.
6. Publish aggregate results instead of raw logs where raw context is not
   necessary.

The curated files under `results/` follow that policy. They preserve tested
hardware/software facts and aggregate measurements while omitting identifying
host, network, user, and project data.
