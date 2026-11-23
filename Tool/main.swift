// The `rhino` command line tool as the Xcode project builds it, to put it
// inside the app. The tool itself is the RhinoCLI library; the package
// builds the same thing with `swift build --product rhino`.
import RhinoCLI

RhinoCommand.main()
