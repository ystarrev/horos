## Build instructions

### Prerequisites

1. `cmake` and `pkg-config` must be in the system's `PATH` or installed at `/opt/local/bin` (Intel) or `/opt/homebrew/bin` (Apple Silicon).
2. Patience or a fast Mac, a full build takes from 5 minutes to 30 minutes.

### Build

1. Clone the repository: `git clone https://github.com/frnext/horos.git`

### Option 1 (GUI)

1. Open `Horos.xcodeproj` in Xcode
2. Build (Command+B)

### Option 2 (terminal)

1. Go to the project root directory
2. `make`

## Additional remarks

The project uses git submodules and depends on files that are in a zipped format.
The build process takes care of these dependencies, but you can invoke the steps manually:

- To unzip the binaries, you can build the target `Unzip Binaries`
- To initialize the submodules: `git submodule update --init --recursive`

DCMTK is pinned to unmodified upstream source. Horos-specific C-GET transfer
selection lives in `Horos/Sources/HorosQueryRetrieveServer.cpp`, using DCMTK's
public APIs. The dependency build refuses local DCMTK source edits, including
patches left in an older checkout. Review and back up any wanted local edits
before restoring that submodule to its pinned revision. Do not reapply the old
C-GET patch.

Listener verification is described in `Scripts/tests/HorosQueryRetrieveTests.md`.

For more information on this code, visit [horosproject.org](https://horosproject.org/get-involved/)
