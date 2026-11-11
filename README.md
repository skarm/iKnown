# iKnow for macOS

iKnow is a native macOS app for exploring the personal knowledge graph that Apple Intelligence builds on your Mac. Browse people, organizations, and events, follow their connections, and inspect the underlying records, confidence scores, and sources.

This project is a SwiftUI adaptation of Eighth Rank’s original web app. It adapts the upstream reports for a desktop interface and reads snapshots in the original `--bundle` format. [Original 8rank/iKnow project](https://github.com/8rank/iKnow) · [Eighth Rank’s research](https://8rank.ai/game/apple-intelligence-personal-knowledge-graph)

## Build and run

iKnow runs on Apple Silicon Macs with macOS 26 or later. The build has been verified with Xcode 27.2. The app uses SwiftUI, Swift Charts, and system SQLite, with no third-party dependencies.

Open `iKnow.xcodeproj` in Xcode and run the **iKnow** scheme, or build from the project directory in Terminal.

```sh
xcodebuild -project iKnow.xcodeproj -scheme iKnow \
  -configuration Release -derivedDataPath build \
  -destination 'generic/platform=macOS' build
open build/Build/Products/Release/iKnow.app
```

## Choose a data source

On first launch, choose **Demo Data** or **This Mac**. iKnow remembers that choice. Use the toolbar’s data source menu to switch sources or open a copy later.

- **Demo** uses synthetic SQLite data in memory and requires no extra permissions.
- **This Mac** reads `~/Library/IntelligencePlatform/graph.db` and related local stores. To grant access, add the built `iKnow.app` under **System Settings → Privacy & Security → Full Disk Access**, then quit and reopen it. You can turn off Full Disk Access when you’re done.
- **Open a Copy of graph.db…** opens a SQLite copy of the graph. Reports that depend on additional stores are available only when the required data is present.
- **Open a Store Snapshot…** opens a folder in the upstream `--bundle` layout. The folder must contain `graph/graph.db`. Companion databases can sit under `graph/Artifacts/` or use flattened names such as `graph/Artifacts__entityTagging__entityTagging.db`. Include `sources/`, `ontology/`, and `biome/` when available. For Photos, iKnow accepts `sources/Photos.sqlite` or `sources/Photos Library.photoslibrary/database/Photos.sqlite`.

The app works offline and opens databases on disk in read-only mode. Use SQLite’s backup command to make a consistent copy of a live database. An existing file copy can omit recent changes if its matching `-wal` file is missing. Report availability depends on the selected source and the private database schemas used by that version of macOS.

## Explore the graph

- Use **Graph Catalog** to search by name, address, or ID with ⌘F. Select an entity to see its connections and open the evidence inspector.
- Open **Dashboard** for an overview of people, events, and activity. In **Social Connections**, select a node to inspect its members and supporting records.
- Browse reports on kinship, communication metadata, photo clusters, Calendar, identities, retracted records, and related stores. Open a photo cluster to see shared appearances and any available local previews.
- Press ⇧⌘P to hide personal fields and photo previews on screen. Press ⌥⌘S to toggle the sidebar and ⌘R to refresh the current source.

## Checks and license

Run the report checks against synthetic in-memory and on-disk SQLite fixtures.

```sh
sh Tests/check.sh
```

The [macOS CI workflow](.github/workflows/ci.yml) checks the Xcode project, runs the report tests, and compiles a Debug build on branch pushes and pull requests. Pushing a tag builds a Release app for Apple Silicon and publishes `iKnow-macOS-arm64.zip` and its `.sha256` checksum on the tag’s GitHub Release. Version tags such as `v1.0.0` set the app version in the Release build. To build an existing tag, open **Actions → macOS CI → Run workflow**, select the default branch, and enter the tag. The app uses ad hoc signing.

Licensed under the [Apache License 2.0](LICENSE).
