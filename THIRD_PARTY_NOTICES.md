# Third-Party Notices

## GitHub `.gitignore` templates

Durepo's built-in ecosystem-aware exclusion rule catalog is informed by the language,
framework, and tool patterns published in GitHub's `github/gitignore` repository:

- Source: https://github.com/github/gitignore
- License: Creative Commons Zero v1.0 Universal (CC0-1.0)
- Use in Durepo: names of well-known dependency, cache, and build-output paths

The catalog is implemented locally in Swift and does not download templates or send
repository information over the network. Durepo adds a catalog rule only after detecting
supporting project metadata and the corresponding path, and rejects suggestions that
would match Git-tracked content.
