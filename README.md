# LaunchBox PowerShell Scripts

A collection of **PowerShell scripts** used to **manipulate, normalize, and align data** with **LaunchBox / Big Box** configurations.  
This repo is intended as a toolbox for cleaning metadata, mass-updating fields, transforming files, and generating/repairing LaunchBox-friendly outputs.

## Goals

- Keep LaunchBox data consistent and predictable
- Reduce manual editing inside LaunchBox by automating bulk changes
- Provide repeatable workflows for importing, cleaning, and restructuring data
- Store scripts in one place with documentation and examples

## What You’ll Find Here

Scripts may include tasks like:

- Cleaning/normalizing game titles (region tags, punctuation, casing, etc.)
- Renaming ROM/media files to match LaunchBox entries (or vice versa)
- Converting and transforming data sources (CSV/JSON/XML) into LaunchBox-aligned formats
- Finding duplicates / mismatches across Platforms, Playlists, and Metadata
- Bulk edits to LaunchBox XML files (with backups and safety checks)
- Auditing missing media or broken paths
- Generating reports for import review

> ⚠️ Many LaunchBox settings and game libraries are stored in XML. Scripts that modify XML should be used carefully and always with backups.
