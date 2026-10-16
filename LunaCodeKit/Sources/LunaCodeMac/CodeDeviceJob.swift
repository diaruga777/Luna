import Foundation
import LunaCodeCore

extension CodeJobs {
    func runOnDevice(_ request: CodeRequest, project: CodeProject, job: CodeJob, process: CodeProcess, log: URL) async throws {
        guard let options = request.deviceBuild else { throw CodeFailure("Choose a phone first.") }
        let phones = try await CodeDeviceSupport.devices(root: root)
        guard phones.contains(where: { $0.id == options.deviceID }) else { throw CodeFailure("The selected phone is disconnected. Connect and unlock it, then try again.") }
        let checkout = try await CodeDeviceCheckout.create(project: project, branch: options.branch, root: root,
            name: job.id, process: process)
        do {
            let buildProject = checkout.project
            let destination = "platform=iOS,id=" + options.deviceID
            let settings = try await CodeDeviceSupport.settings(buildProject, root: root, process: process, destination: destination)
            guard let app = settings.first, CodeDeviceSupport.isApp(app),
                  let bundle = app["PRODUCT_BUNDLE_IDENTIFIER"], !bundle.lowercased().contains("webdriveragent"),
                  let product = app["FULL_PRODUCT_NAME"], product.hasSuffix(".app") else {
                throw CodeFailure("Choose a runnable iOS app scheme in the row menu.")
            }
            let derived = derivedData(project).appendingPathComponent("Device")
            let products = derived.appendingPathComponent("Products")
            try await command("/usr/bin/xcodebuild", buildProject.xcodeArguments + ["-configuration", "Debug", "-destination", destination,
                "-derivedDataPath", derived.path, "-resultBundlePath", root.appendingPathComponent(job.id + ".xcresult").path,
                "-allowProvisioningUpdates", "CONFIGURATION_BUILD_DIR=" + products.path, "build"], directory: checkout.directory.path, process: process, log: log)
            let appURL = products.appendingPathComponent(product)
            // Read the actual built product so scheme dependencies cannot change the install target.
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: appURL.appendingPathComponent("Info.plist")), format: nil) as? [String: Any]
            guard plist?["CFBundleIdentifier"] as? String == bundle else { throw CodeFailure("The built app does not match the selected scheme.") }
            try await command("/usr/bin/xcrun", ["devicectl", "device", "install", "app", "--device", options.deviceID, appURL.path], directory: checkout.directory.path, process: process, log: log)
            try await command("/usr/bin/xcrun", ["devicectl", "device", "process", "launch", "--device", options.deviceID, "--terminate-existing", bundle], directory: checkout.directory.path, process: process, log: log)
        } catch {
            await checkout.remove(root: root)
            throw error
        }
        await checkout.remove(root: root)
    }
    private func command(_ executable: String, _ arguments: [String], directory: String, process: CodeProcess, log: URL) async throws {
        guard try await process.run(executable, arguments, directory: directory, log: log) == 0 else { throw CodeFailure("Build & Run stopped. See the Mac job log for details.") }
    }
}

/// A detached checkout protects the editor's branch, index and unsaved Mac files.
struct CodeDeviceCheckout {
    var directory: URL
    var repository: String
    var project: CodeProject
    static func create(project: CodeProject, branch: String, root: URL, name: String, process: CodeProcess = CodeProcess()) async throws -> Self {
        let repository = try await CodeDeviceSupport.git(["rev-parse", "--show-toplevel"], directory: project.root, root: root, process: process)
        let source = URL(fileURLWithPath: project.path).resolvingSymlinksInPath().path
        let repo = URL(fileURLWithPath: repository).resolvingSymlinksInPath().path
        guard source.hasPrefix(repo + "/"), !branch.isEmpty else { throw CodeFailure("The project must be inside a Git repository with a main branch.") }
        let revision = try await CodeDeviceSupport.git(["rev-parse", "--verify", "--end-of-options", branch + "^{commit}"], directory: repo, root: root, process: process)
        let directory = root.appendingPathComponent("Checkout-" + name)
        do {
            _ = try await CodeDeviceSupport.git(["worktree", "add", "--detach", directory.path, revision], directory: repo, root: root, process: process)
        } catch {
            _ = try? await CodeDeviceSupport.git(["worktree", "remove", "--force", directory.path], directory: repo, root: root)
            throw error
        }
        var selected = project
        selected.path = directory.appendingPathComponent(String(source.dropFirst(repo.count + 1))).path
        return Self(directory: directory, repository: repo, project: selected)
    }
    func remove(root: URL) async {
        _ = try? await CodeDeviceSupport.git(["worktree", "remove", "--force", directory.path], directory: repository, root: root)
    }
}
