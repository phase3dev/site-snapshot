# Changelog

All notable changes to this project will be documented in this file.

## [1.0.2] - 2026-04-22
### Added

- Added repeatable `--proxy URL` support for inline proxy values.
- Added repeatable `--user-agent STRING` support for inline user-agent values.
- Added merging of file-based and inline proxy/user-agent sources.
- Added deduplication across file-based and inline proxy/user-agent entries.

### Fixed

- Fixed end-of-run hang caused by overly broad waiting on background processes.
- Fixed retry handling under `set -euo pipefail`, so failed `wget` calls now properly retry instead of potentially terminating early.
- Improved argument validation for required option values.
- Improved handling of blank and comment lines in proxy and user-agent files.
- Improved normalization of `--domains` so full URLs are accepted and reduced to valid domain values.

### Improved

- Added fallback discovery pass that scans downloaded HTML for additional internal URLs and feeds them back into `wget`.
- Added `--discover-off`, `--discover-passes N`, `--discover-limit N`, and `--scope-prefixes PREFIXES`.
- Added `--convert-links` for better offline browsing.
- Expanded logging so proxy and user-agent sources are clearer, including inline counts.
