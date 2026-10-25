# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Simple Comic is a streamlined comic viewer for macOS (CBR/CBZ/other archives, PDFs, image folders). Its design goal is to minimize the number of interactions needed to read a comic. It ships with **Quick Comic**, a bundled QuickLook generator for thumbnails and previews of `.cbr`/`.cbz` files.

The code is Objective-C from 2006–2017 (last commit April 2017, version 1.7.1 / build 253), MIT licensed (`license.txt`). The project went dormant for roughly 8 years.

## Current goal: modernize so it builds natively on Apple silicon

The main task in this repo right now is to bring the project up to date so it compiles and runs as a native arm64 (ideally Universal arm64 + x86_64) app with current Xcode. Keep that goal in mind for every change. Prefer the smallest change that gets the build working over broad refactors, and keep behavior the same unless a change is required to build.

### Status

The app now builds, signs (ad hoc), and launches as a native arm64 app with Xcode 27. A test CBZ opened without crashing. What was done:

- **XADMaster is built from source.** The old checked-in `Frameworks/XADMaster.framework` was x86_64 only and has been removed. `Vendor/XADMaster` (MacPaw/XADMaster) and `Vendor/UniversalDetector` (MacPaw/universal-detector) are git submodules. They have to stay sibling directories, because XADMaster's project references `../UniversalDetector`. `scripts/build-frameworks.sh` builds both as Universal frameworks into `Frameworks/`, which is gitignored. The modern XADMaster loads **UniversalDetector.framework as a separate dylib** (weak-linked), so the app embeds both. Both are in the "CopyFiles" phase (destination Frameworks) with `CodeSignOnCopy`; without that, signing the app fails with "code object is not signed at all".
- **Deployment target is 12.0**, the lowest Xcode 27 accepts, in both projects. The script overrides the vendored projects' 10.9 on the command line, so don't edit files inside `Vendor/`.
- **Removed obsolete flags:** SSE3, G4 tuning, `-mdynamic-no-pic`, `ZERO_LINK`, and others. `-lstdc++` is now `-lc++` in the `Default` configuration.
- **Fixed `.strings` encodings:** `English.lproj/{Localizable,InfoPlist}.strings` were declared as Mac Roman (`fileEncoding = 30`) but are UTF-8, which made the build fail.
- **Comic types match by file extension only.** The Comic Zip/Rar/7-Zip entries in `CFBundleDocumentTypes` deliberately have no `LSItemContentTypes`. When that key is present, Launch Services ignores `CFBundleTypeExtensions`, and `.cbz`/`.cbr` resolve to whichever UTI another installed app exports (on the dev machine, YACReader's `com.yacreader.yacreader.cbz`). In that case Simple Comic disappears from Finder's Open With menu. To check: `lsregister -f <app>`, then ask `NSWorkspace.urlsForApplications(toOpen:)`.
- **The legacy binary Core Data model** (`elements`/`layout` instead of an XML `contents` file) still compiles with current `momc`, so no conversion is needed.

### Remaining issues and risks

- **QuickLook `.qlgenerator` plugins are deprecated.** QuickComic builds and is embedded, but recent macOS releases don't load `.qlgenerator` plugins. QuickLook Preview/Thumbnail *app extensions* replace them, and porting to those is a separate task.
- **Manual retain/release (MRC), not ARC.** About 17 files call `retain`/`release`/`autorelease` explicitly. Don't turn on ARC as part of the arm64 work unless asked.
- **Leftover warnings:** the build emits about 90, mostly deprecated APIs (for example `metadataForPersistentStoreOfType:URL:error:` and `propertyListFromData:...`). There is also a `CFBundleIdentifier` / `PRODUCT_BUNDLE_IDENTIFIER` mismatch warning, and a "Traditional headermap" warning in QuickComic.
- **Old project format:** the files still say `objectVersion = 46` and `LastUpgradeCheck = 0500`. Opening them in the Xcode GUI will offer "recommended settings" upgrades; review those before accepting.
- **Leftover Sparkle configuration:** `Info.plist` has `SUFeedURL` (a dead http URL) and `SUPublicDSAKeyFile`, but Sparkle isn't linked.
- **Shared user data:** the dev build uses the same bundle ID (`com.tsst.simplecomic`) and Core Data store (`~/Library/Application Support/Simple Comic/SimpleComic.sql`) as any installed release, so testing reads and writes the user's real session history. Don't modify or inspect that store's contents.

## Building

Building requires full Xcode. If `xcode-select` points at the Command Line Tools, set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` or run `sudo xcode-select -s /Applications/Xcode.app`.

```bash
# One-time setup (and after updating the submodules): build the vendored frameworks into Frameworks/
git submodule update --init
scripts/build-frameworks.sh

# Build the app (also builds QuickComic as a target dependency and embeds it)
xcodebuild -project SimpleComic.xcodeproj -target "Simple Comic" -configuration Debug \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- build
# For a Universal app, use ARCHS="arm64 x86_64"

# Verify the architectures and signature, then launch
lipo -info "build/Debug/Simple Comic.app/Contents/MacOS/Simple Comic"
codesign --verify --deep --strict "build/Debug/Simple Comic.app"
open "build/Debug/Simple Comic.app"
```

`.gitattributes` marks `*.pbxproj` as `-diff -merge`, so plain `git diff` shows project-file changes as binary. Use `git diff --text` to review them, and `plutil -lint <path>/project.pbxproj` to check the syntax after hand edits.

There are no unit tests, linters, or CI configs. To verify a change, build it and then launch the app and open a CBZ/CBR/PDF/folder.

## Architecture

**The data model is Core Data, and archives are opened lazily.** All persistent state lives in a Core Data store (`Sessions_DataModel`) in Application Support. Sessions are auto-saved on a timer and restored at launch. The managed object classes are in `Managed Objects/`:
- `TSSTManagedSession`: one reader window's state (open files and view settings).
- `TSSTManagedGroup`: a container of pages. Its subclasses are `TSSTManagedArchive` (backed by an `XADArchive`) and `TSSTManagedPDF` (backed by a `PDFDocument`). A plain group is a folder. Groups nest (archives inside archives or folders). The backing object is created lazily in `-instance` and shared under an `NSLock`. Page bytes come from `dataForPageIndex:` / `dataForPageName:`.
- `TSSTPage`: a single image, PDF page, or text file. It gets its bytes from its group, caches size info (used to decide whether to show it alone or in a two-page spread), and generates thumbnails behind its own locks because thumbnails are produced on background `NSThread`s.

**The app delegate** (`SimpleComicAppDelegate`) owns the Core Data stack. It turns file paths into groups and pages (`addFiles:toSession:`), creates and restores sessions, and is the `XADArchive` delegate for password prompts and fallback filename encoding selection (an encoding panel that grays out encodings that fail on sample data). The user-defaults keys are the `TSST*` string constants declared in `SimpleComicAppDelegate.h`.

**The session window.** `TSSTSessionWindowController` (`Session/`) is the main controller, one per session. It binds an `NSArrayController` of pages and decides page navigation and two-page-spread layout, including right-to-left order and a "lonely first page". It also handles fullscreen, the loupe, the progress bar scrubbing popup (`TSSTInfoWindow`), page extraction and cropping, and the thumbnail "expose" view. Drawing and event handling are in `TSSTPageView`, which composites one or two `NSImage`s and contains no aspect-ratio logic. The controller supplies that through the `DTPageLayout_Protocol`, `DTPageSource_Protocol`, and `DTPageSelection_Protocol` protocols declared in `TSSTPageView.h`. UI is defined in `English.lproj/*.xib` and wired through IBOutlets and Cocoa bindings, so renaming a property or method can silently break a nib binding.

**QuickComic is a separate project with duplicated helpers.** `QuickComic/` has its own copies of `TSSTImageUtilities`, `TSSTSortDescriptor`, and `UKXattrMetadataStore`, and they have **diverged** from the versions in `Helpers/`. A fix in one copy is not automatically in the other. `DTPartialArchiveParser` uses `XADArchiveParser` delegate callbacks to pull a single entry (the cover) without fully opening the archive.

**Other pieces:** `Custom Windows/` (the borderless fullscreen key window, the bezel window for the thumbnail view, and an `NSWindow` category), `Progress Bar/` (custom-drawn progress bar and info popup), `Preferences/`, `SComic.sdef` (AppleScript dictionary), and `Localization/` (Localizer `.loc` bundles for 8 languages; English is the only `.lproj` in the build).

## Conventions

- Class prefixes: `TSST` is the original code, `DT` is newer code (Dancing Tortoise), and `UK` is third-party (UKXattrMetadataStore).
- Every source file starts with a copyright/MIT license header block, which new files should keep.
- The style is ivar-heavy headers with `IBOutlet` ivars and only a few `@property` declarations. Follow the existing style in files you touch.
