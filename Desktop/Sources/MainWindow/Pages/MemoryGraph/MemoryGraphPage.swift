import SwiftUI
import SceneKit

// MARK: - Memory Graph Page

struct MemoryGraphPage: View {
    @StateObject private var viewModel = MemoryGraphViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            // Full-bleed background + 3D scene
            FazmColors.backgroundSecondary.ignoresSafeArea()

            if !viewModel.isEmpty {
                MemoryGraphSceneView(viewModel: viewModel)
                    .ignoresSafeArea()
            }

            // Minimal floating controls — no boxes, no backgrounds
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .scaledFont(size: 13, weight: .semibold)
                            .foregroundColor(.white.opacity(0.5))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    if viewModel.isRebuilding {
                        ProgressView()
                            .scaleEffect(0.6)
                            .tint(.white.opacity(0.5))
                    } else {
                        Button {
                            Task { await viewModel.rebuildGraph() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .scaledFont(size: 13)
                                .foregroundColor(.white.opacity(0.5))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .help("Rebuild graph")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                Spacer()
            }

            // Loading spinner: only while a load/rebuild is actively in flight,
            // or before the initial attempt has completed. Without `didAttemptLoad`,
            // an empty graph would keep the spinner on screen forever.
            if viewModel.isLoading || viewModel.isRebuilding || !viewModel.didAttemptLoad {
                ProgressView()
                    .scaleEffect(1.2)
                    .tint(.white.opacity(0.4))
            } else if viewModel.isEmpty {
                MemoryGraphEmptyState(isRebuilding: viewModel.isRebuilding) {
                    Task { await viewModel.rebuildGraph() }
                }
            }
        }
        .task {
            await viewModel.loadGraph()
            // Fresh installs / users mid-file-indexing start empty while
            // save_knowledge_graph writes land in the background. Retry via
            // rebuildGraph (which also invalidates the cached DB handle) so we
            // recover both the "not written yet" and "stale DB handle" cases
            // before settling on the empty state.
            if viewModel.isEmpty {
                for _ in 1...10 {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await viewModel.rebuildGraph()
                    if !viewModel.isEmpty { break }
                }
            }
            viewModel.didAttemptLoad = true
        }
    }
}

// MARK: - Empty State

private struct MemoryGraphEmptyState: View {
    let isRebuilding: Bool
    let onRebuild: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "circle.grid.cross")
                .scaledFont(size: 28)
                .foregroundColor(.white.opacity(0.35))
            Text("No memory yet")
                .scaledFont(size: 14, weight: .semibold)
                .foregroundColor(.white.opacity(0.75))
            Text("Chat with Fazm or let it explore your files. Your knowledge graph builds up over time.")
                .scaledFont(size: 12)
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if !isRebuilding {
                Button(action: onRebuild) {
                    Text("Try again")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
    }
}

// MARK: - SceneKit View

struct MemoryGraphSceneView: NSViewRepresentable {
    @ObservedObject var viewModel: MemoryGraphViewModel

    func makeNSView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.scene = viewModel.scene
        scnView.pointOfView = viewModel.cameraNode
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = false // We set up our own lights
        scnView.backgroundColor = NSColor(red: 0x1A/255.0, green: 0x1A/255.0, blue: 0x1A/255.0, alpha: 1.0) // Match FazmColors.backgroundSecondary
        scnView.antialiasingMode = .multisampling2X // Lighter AA
        scnView.preferredFramesPerSecond = 30 // Cap render rate

        // Set up delegate for animation
        scnView.delegate = context.coordinator

        return scnView
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        // Update scene if needed
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    class Coordinator: NSObject, SCNSceneRendererDelegate {
        let viewModel: MemoryGraphViewModel
        private var lastUpdateTime: TimeInterval = 0

        init(viewModel: MemoryGraphViewModel) {
            self.viewModel = viewModel
        }

        func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
            // Throttle to ~30fps for physics updates
            guard time - lastUpdateTime > 0.033 else { return }
            lastUpdateTime = time
            Task { @MainActor in
                viewModel.updateSimulation()
            }
        }
    }
}

// MARK: - View Model

@MainActor
class MemoryGraphViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var isRebuilding = false
    @Published var isEmpty = true
    @Published var selectedNodeId: String?
    /// Set true after the first .task completes its load attempts (including retries).
    /// Used by the view to switch from spinner → empty state when no nodes were found,
    /// instead of spinning forever.
    @Published var didAttemptLoad = false

    let scene = SCNScene()
    let cameraNode = SCNNode()

    private var simulation = ForceDirectedSimulation()
    private var nodeSceneNodes: [String: SCNNode] = [:]
    private var edgeSceneNodes: [String: SCNNode] = [:]
    private var isAnimating = true

    /// Maximum number of nodes to render in SceneKit (top by connection count)
    private let maxVisibleNodes = 100
    /// Minimum connection count to show a glow halo
    private let glowConnectionThreshold = 3
    /// Minimum connection count to show a text label
    private let labelConnectionThreshold = 2

    /// Debounce timer for incremental graph updates
    private var graphUpdateDebounceTask: Task<Void, Never>?
    private var hasPendingGraphUpdate = false

    /// Cache for pre-rendered label textures
    private var labelTextureCache: [String: NSImage] = [:]

    init() {
        setupCamera()
        setupLighting()
    }

    private func setupCamera() {
        let camera = SCNCamera()
        camera.zNear = 1
        camera.zFar = 20000
        camera.fieldOfView = 60
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 2000) // Initial default, auto-adjusted after layout
        scene.rootNode.addChildNode(cameraNode)
    }

    private func setupLighting() {
        // Ambient light
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 500
        ambientLight.color = NSColor.white
        let ambientNode = SCNNode()
        ambientNode.light = ambientLight
        scene.rootNode.addChildNode(ambientNode)

        // Directional light
        let directionalLight = SCNLight()
        directionalLight.type = .directional
        directionalLight.intensity = 800
        let directionalNode = SCNNode()
        directionalNode.light = directionalLight
        directionalNode.position = SCNVector3(0, 1000, 1000)
        directionalNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(directionalNode)
    }

    // MARK: - Node Capping

    /// Filter a graph response to only include the top nodes by connection count.
    /// Always includes the user node. Edges are filtered to only reference included nodes.
    private func capGraphResponse(_ response: KnowledgeGraphResponse, maxNodes: Int, userNodeLabel: String?) -> KnowledgeGraphResponse {
        guard response.nodes.count > maxNodes else { return response }

        // Count connections per node
        var connectionCounts: [String: Int] = [:]
        for edge in response.edges {
            connectionCounts[edge.sourceId, default: 0] += 1
            connectionCounts[edge.targetId, default: 0] += 1
        }

        // Sort by connection count descending, keep top N
        let sorted = response.nodes.sorted { (connectionCounts[$0.id] ?? 0) > (connectionCounts[$1.id] ?? 0) }
        var kept = Array(sorted.prefix(maxNodes))

        // Ensure user node is included
        if let userName = userNodeLabel,
           !kept.contains(where: { $0.label.lowercased() == userName.lowercased() }),
           let userNode = response.nodes.first(where: { $0.label.lowercased() == userName.lowercased() }) {
            kept.append(userNode)
        }

        let keptIds = Set(kept.map { $0.id })
        let filteredEdges = response.edges.filter { keptIds.contains($0.sourceId) && keptIds.contains($0.targetId) }

        log("Knowledge graph capped: \(response.nodes.count) → \(kept.count) nodes, \(response.edges.count) → \(filteredEdges.count) edges")
        return KnowledgeGraphResponse(nodes: kept, edges: filteredEdges)
    }

    // MARK: - Load Graph

    func loadGraph() async {
        isLoading = true
        defer { isLoading = false }

        // Local SQLite is the only source of truth. The graph is built
        // incrementally by the save_knowledge_graph tool during chat + file
        // exploration; there is no remote knowledge-graph backend.
        var response = await KnowledgeGraphStorage.shared.loadGraph()

        log("Knowledge graph: \(response.nodes.count) nodes, \(response.edges.count) edges")
        isEmpty = response.nodes.isEmpty

        guard !isEmpty else { return }

        // Cap to top nodes by connection count for rendering performance
        let userName = AuthService.shared.displayName.isEmpty ? nil : AuthService.shared.givenName
        response = capGraphResponse(response, maxNodes: maxVisibleNodes, userNodeLabel: userName)

        // Populate simulation with user node at center
        log("User name for center node: \(userName ?? "nil")")
        simulation.populate(graphResponse: response, userNodeLabel: userName)
        log("Simulation populated: \(simulation.nodes.count) nodes (including user), \(simulation.edges.count) edges")

        // Run initial layout off main thread for responsiveness
        await Task.detached(priority: .userInitiated) { [simulation] in
            simulation.runSync(ticks: 800)
        }.value

        // Create scene nodes in batches to avoid blocking main thread
        await createSceneNodes()

        // Brief animation to settle, then stop
        isAnimating = true
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s of live physics
            await MainActor.run { isAnimating = false }
        }
    }

    // MARK: - Rebuild Graph

    /// "Rebuild" re-reads the local knowledge graph from disk. There is no
    /// remote rebuild backend — the graph is populated incrementally by the
    /// save_knowledge_graph tool. Invalidating the cached DB handle first
    /// recovers the case where the graph was written under a different user
    /// DB path than the one the first read resolved (stale `_dbQueue`).
    func rebuildGraph() async {
        isRebuilding = true
        defer { isRebuilding = false }

        await KnowledgeGraphStorage.shared.invalidateCache()
        await loadGraph()
    }

    // MARK: - Incremental Graph Update

    /// Debounced entry point — buffers rapid save_knowledge_graph calls into a single update.
    func addGraphFromStorage() async {
        // Cancel any pending debounce and schedule a new one
        graphUpdateDebounceTask?.cancel()
        hasPendingGraphUpdate = true
        graphUpdateDebounceTask = Task { [weak self] in
            // Wait 5 seconds to coalesce rapid calls
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.performIncrementalGraphUpdate()
        }
    }

    /// Actually performs the incremental graph update after debounce settles.
    private func performIncrementalGraphUpdate() async {
        guard hasPendingGraphUpdate else { return }
        hasPendingGraphUpdate = false

        var response = await KnowledgeGraphStorage.shared.loadGraph()
        guard !response.nodes.isEmpty else { return }
        isEmpty = false

        // Cap the response before feeding to simulation
        let userName = AuthService.shared.displayName.isEmpty ? nil : AuthService.shared.givenName
        response = capGraphResponse(response, maxNodes: maxVisibleNodes, userNodeLabel: userName)

        let previousNodeCount = simulation.nodes.count
        simulation.addNodesAndEdges(graphResponse: response, userNodeLabel: userName)
        let addedNodes = simulation.nodes.count - previousNodeCount

        // Scale physics burst to number of new nodes (skip if only 1-2 added)
        if addedNodes > 2 {
            let ticks = min(200, addedNodes * 20)
            await Task.detached(priority: .userInitiated) { [simulation] in
                simulation.runSync(ticks: ticks)
            }.value
        }

        // Create scene nodes for new entries, animate them in
        await addNewSceneNodes()
        autoFitCamera(animated: true)

        // Re-enable animation for settling (shorter window)
        isAnimating = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { self.isAnimating = false }
        }
    }

    /// Create scene nodes only for simulation nodes/edges not yet in the scene (batched to avoid app hangs)
    private func addNewSceneNodes() async {
        let billboardConstraint = SCNBillboardConstraint()
        billboardConstraint.freeAxes = [.X, .Y]

        // Add new edges in batches
        let newEdges = simulation.edges.filter { edgeSceneNodes[$0.id] == nil }
        for (index, edge) in newEdges.enumerated() {
            guard let source = simulation.nodeMap[edge.sourceId],
                  let target = simulation.nodeMap[edge.targetId] else { continue }

            let edgeColor = blendColors(source.nodeType.nsColor, target.nodeType.nsColor, alpha: 0.25)
            let edgeMaterial = SCNMaterial()
            edgeMaterial.diffuse.contents = edgeColor
            edgeMaterial.emission.contents = edgeColor.withAlphaComponent(0.15)
            edgeMaterial.lightingModel = .constant

            let edgeNode = createEdgeNode(from: source.position, to: target.position, material: edgeMaterial)
            edgeNode.name = edge.id
            edgeNode.opacity = 0
            scene.rootNode.addChildNode(edgeNode)
            edgeSceneNodes[edge.id] = edgeNode

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.5
            edgeNode.opacity = 1
            SCNTransaction.commit()

            if index > 0 && index % 20 == 0 {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }

        // Add new node spheres in batches
        let newNodes = simulation.nodes.filter { nodeSceneNodes[$0.id] == nil }
        for (index, node) in newNodes.enumerated() {
            let containerNode = createNodeSceneNode(node, billboardConstraint: billboardConstraint)
            containerNode.scale = SCNVector3(0.01, 0.01, 0.01)

            scene.rootNode.addChildNode(containerNode)
            nodeSceneNodes[node.id] = containerNode

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.5
            containerNode.scale = SCNVector3(1, 1, 1)
            SCNTransaction.commit()

            if index > 0 && index % 10 == 0 {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
    }

    // MARK: - Scene Nodes

    /// Compute node radius based on connection count (more connections = bigger)
    private func nodeRadius(for node: GraphNode3D) -> CGFloat {
        if node.isFixed { return 35 } // User node is largest
        let base: CGFloat = 14
        let connectionBonus = CGFloat(min(node.connectionCount, 10)) * 2.5
        return base + connectionBonus
    }

    private func createSceneNodes() async {
        // Clear existing nodes
        for (_, node) in nodeSceneNodes { node.removeFromParentNode() }
        for (_, node) in edgeSceneNodes { node.removeFromParentNode() }
        nodeSceneNodes.removeAll()
        edgeSceneNodes.removeAll()
        labelTextureCache.removeAll()

        let billboardConstraint = SCNBillboardConstraint()
        billboardConstraint.freeAxes = [.X, .Y]

        // Create edges in batches (behind nodes)
        for (index, edge) in simulation.edges.enumerated() {
            guard let source = simulation.nodeMap[edge.sourceId],
                  let target = simulation.nodeMap[edge.targetId] else { continue }

            let edgeColor = blendColors(source.nodeType.nsColor, target.nodeType.nsColor, alpha: 0.25)
            let edgeMaterial = SCNMaterial()
            edgeMaterial.diffuse.contents = edgeColor
            edgeMaterial.emission.contents = edgeColor.withAlphaComponent(0.15)
            edgeMaterial.lightingModel = .constant

            let edgeNode = createEdgeNode(from: source.position, to: target.position, material: edgeMaterial)
            edgeNode.name = edge.id
            scene.rootNode.addChildNode(edgeNode)
            edgeSceneNodes[edge.id] = edgeNode

            if index > 0 && index % 20 == 0 {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }

        // Create node spheres in batches
        for (index, node) in simulation.nodes.enumerated() {
            let containerNode = createNodeSceneNode(node, billboardConstraint: billboardConstraint)
            scene.rootNode.addChildNode(containerNode)
            nodeSceneNodes[node.id] = containerNode

            if index > 0 && index % 10 == 0 {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }

        autoFitCamera()
    }

    /// Creates a single node's SceneKit representation: sphere + optional glow + optional label
    private func createNodeSceneNode(_ node: GraphNode3D, billboardConstraint: SCNBillboardConstraint) -> SCNNode {
        let radius = nodeRadius(for: node)
        let containerNode = SCNNode()
        containerNode.position = SCNVector3(node.position)
        containerNode.name = node.id

        // Core sphere
        let sphere = SCNSphere(radius: radius)
        sphere.segmentCount = node.isFixed ? 24 : 8
        let mat = SCNMaterial()
        if node.isFixed {
            mat.diffuse.contents = NSColor.white
            mat.emission.contents = NSColor.white.withAlphaComponent(0.8)
        } else {
            mat.diffuse.contents = node.nodeType.nsColor
            mat.emission.contents = node.nodeType.nsColor.withAlphaComponent(0.5)
        }
        mat.lightingModel = .constant
        sphere.materials = [mat]
        containerNode.addChildNode(SCNNode(geometry: sphere))

        // Glow halo — only for user node or well-connected nodes
        if node.isFixed || node.connectionCount >= glowConnectionThreshold {
            let glowRadius = radius * 2.5
            let glowSphere = SCNSphere(radius: glowRadius)
            glowSphere.segmentCount = 8
            let glowMat = SCNMaterial()
            let glowColor = node.isFixed ? NSColor.white : node.nodeType.nsColor
            glowMat.diffuse.contents = glowColor.withAlphaComponent(0.03)
            glowMat.emission.contents = glowColor.withAlphaComponent(0.025)
            glowMat.lightingModel = .constant
            glowMat.isDoubleSided = true
            glowMat.blendMode = .add
            glowSphere.materials = [glowMat]
            containerNode.addChildNode(SCNNode(geometry: glowSphere))
        }

        // Text label — only for user node or nodes with enough connections
        if node.isFixed || node.connectionCount >= labelConnectionThreshold {
            let labelNode = createLabelNode(text: node.label, nodeRadius: radius, isFixed: node.isFixed)
            labelNode.constraints = [billboardConstraint]
            containerNode.addChildNode(labelNode)
        }

        return containerNode
    }

    /// Create a text label as a billboarded texture plane (much cheaper than SCNText)
    private func createLabelNode(text: String, nodeRadius: CGFloat, isFixed: Bool) -> SCNNode {
        let truncated = text.count > 18 ? String(text.prefix(16)) + "..." : text
        let cacheKey = "\(truncated)_\(isFixed)"

        // Render text to NSImage (cached)
        let image: NSImage
        if let cached = labelTextureCache[cacheKey] {
            image = cached
        } else {
            image = renderLabelTexture(text: truncated, isFixed: isFixed)
            labelTextureCache[cacheKey] = image
        }

        // Create a plane with the texture
        let aspectRatio = image.size.width / image.size.height
        let planeHeight: CGFloat = isFixed ? 28 : 20
        let planeWidth = planeHeight * aspectRatio
        let plane = SCNPlane(width: planeWidth, height: planeHeight)

        let planeMat = SCNMaterial()
        planeMat.diffuse.contents = image
        planeMat.emission.contents = image
        planeMat.lightingModel = .constant
        planeMat.isDoubleSided = true
        planeMat.transparencyMode = .aOne
        plane.materials = [planeMat]

        let labelNode = SCNNode(geometry: plane)
        labelNode.position = SCNVector3(0, -(nodeRadius + planeHeight / 2 + 8), 0)

        return labelNode
    }

    /// Pre-render label text into an NSImage texture
    private func renderLabelTexture(text: String, isFixed: Bool) -> NSImage {
        let fontSize: CGFloat = isFixed ? 44 : 32
        let font = NSFont.systemFont(ofSize: fontSize, weight: isFixed ? .bold : .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 8
        let imageSize = NSSize(width: ceil(size.width + padding * 2), height: ceil(size.height + padding * 2))

        let image = NSImage(size: imageSize)
        image.lockFocus()
        (text as NSString).draw(at: NSPoint(x: padding, y: padding), withAttributes: attributes)
        image.unlockFocus()

        return image
    }

    /// Blend two NSColors
    private func blendColors(_ a: NSColor, _ b: NSColor, alpha: CGFloat) -> NSColor {
        let aRGB = a.usingColorSpace(.sRGB) ?? a
        let bRGB = b.usingColorSpace(.sRGB) ?? b
        return NSColor(
            red: (aRGB.redComponent + bRGB.redComponent) / 2,
            green: (aRGB.greenComponent + bRGB.greenComponent) / 2,
            blue: (aRGB.blueComponent + bRGB.blueComponent) / 2,
            alpha: alpha
        )
    }

    /// Auto-fit camera distance to contain all nodes
    private func autoFitCamera(animated: Bool = false) {
        guard !simulation.nodes.isEmpty else { return }

        var maxDist: Float = 0
        for node in simulation.nodes {
            let dist = simd_length(node.position)
            if dist > maxDist { maxDist = dist }
        }

        // Camera needs to be far enough to see the outermost node
        // Account for field of view (60deg) — distance = maxDist / tan(fov/2) + padding
        let fovRadians: Float = 60.0 * Float.pi / 180.0
        let minDistance = maxDist / tan(fovRadians / 2) * 1.3 // 30% padding
        let cameraZ = max(minDistance, 1200) // minimum distance for very small graphs

        if animated {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.8
            cameraNode.position = SCNVector3(0, 0, cameraZ)
            SCNTransaction.commit()
        } else {
            cameraNode.position = SCNVector3(0, 0, cameraZ)
        }
    }

    private func createEdgeNode(from: SIMD3<Float>, to: SIMD3<Float>, material: SCNMaterial) -> SCNNode {
        let fromVec = SCNVector3(from)
        let toVec = SCNVector3(to)

        let distance = sqrt(
            pow(toVec.x - fromVec.x, 2) +
            pow(toVec.y - fromVec.y, 2) +
            pow(toVec.z - fromVec.z, 2)
        )

        let cylinder = SCNCylinder(radius: 0.8, height: CGFloat(distance))
        cylinder.radialSegmentCount = 6
        cylinder.materials = [material]

        let node = SCNNode(geometry: cylinder)
        node.position = SCNVector3(
            (fromVec.x + toVec.x) / 2,
            (fromVec.y + toVec.y) / 2,
            (fromVec.z + toVec.z) / 2
        )
        node.look(at: toVec, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 1, 0))

        return node
    }

    // MARK: - Animation

    func updateSimulation() {
        guard isAnimating, !simulation.isStable else { return }

        simulation.tick()

        // Batch all position updates without animation
        SCNTransaction.begin()
        SCNTransaction.disableActions = true

        for node in simulation.nodes {
            nodeSceneNodes[node.id]?.position = SCNVector3(node.position)
        }

        for edge in simulation.edges {
            guard let source = simulation.nodeMap[edge.sourceId],
                  let target = simulation.nodeMap[edge.targetId],
                  let edgeNode = edgeSceneNodes[edge.id] else { continue }
            updateEdgeNode(edgeNode, from: source.position, to: target.position)
        }

        SCNTransaction.commit()
    }

    private func updateEdgeNode(_ node: SCNNode, from: SIMD3<Float>, to: SIMD3<Float>) {
        let fromVec = SCNVector3(from)
        let toVec = SCNVector3(to)

        let dx = toVec.x - fromVec.x
        let dy = toVec.y - fromVec.y
        let dz = toVec.z - fromVec.z
        let distance = sqrt(dx * dx + dy * dy + dz * dz)

        if let cylinder = node.geometry as? SCNCylinder {
            cylinder.height = CGFloat(distance)
        }
        node.position = SCNVector3(
            (fromVec.x + toVec.x) / 2,
            (fromVec.y + toVec.y) / 2,
            (fromVec.z + toVec.z) / 2
        )
        node.look(at: toVec, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 1, 0))
    }

    // MARK: - Share

    func shareGraph() {
        // TODO: Implement screenshot and share
        log("Share graph - not yet implemented")
    }
}

// MARK: - Extensions

extension KnowledgeGraphNodeType: CaseIterable {
    static var allCases: [KnowledgeGraphNodeType] {
        [.person, .place, .organization, .thing, .concept]
    }

    var displayName: String {
        switch self {
        case .person: return "Person"
        case .place: return "Place"
        case .organization: return "Organization"
        case .thing: return "Thing"
        case .concept: return "Concept"
        }
    }

    var color: Color {
        switch self {
        case .person: return .cyan
        case .place: return Color(red: 0, green: 1, blue: 0.62) // Mint
        case .organization: return .orange
        case .thing: return .purple
        case .concept: return .blue
        }
    }

    var nsColor: NSColor {
        switch self {
        case .person: return .cyan
        case .place: return NSColor(red: 0, green: 1, blue: 0.62, alpha: 1)
        case .organization: return .orange
        case .thing: return .purple
        case .concept: return .systemBlue
        }
    }
}

extension SCNVector3 {
    init(_ simd: SIMD3<Float>) {
        self.init(x: CGFloat(simd.x), y: CGFloat(simd.y), z: CGFloat(simd.z))
    }
}

// MARK: - Preview

#Preview {
    MemoryGraphPage()
        .frame(width: 800, height: 600)
}
