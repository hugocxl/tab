import CGhosttyVT
import Foundation
import TabProtocol

/// Most image bytes sent for one screen.
public let maxGraphicsBytes = 8 * 1024 * 1024
/// Most image placements sent for one screen.
public let maxGraphicsPlacements = 1024

/// Kitty images on screen, with converted pixels cached by image generation.
final class GraphicsCache {
    private var images: [UInt32: GraphicImage] = [:]
    private let iterator: GhosttyRenderStateImageIterator

    init() throws {
        var iterator: GhosttyRenderStateImageIterator?
        try Ghostty.check(ghostty_render_state_image_iterator_new(nil, &iterator), .create)
        guard let iterator else { throw TerminalError(.create, .engine(GHOSTTY_OUT_OF_MEMORY.rawValue)) }
        self.iterator = iterator
    }

    deinit {
        ghostty_render_state_image_iterator_free(iterator)
    }

    /// Reads placements from an up-to-date render state.
    func snapshot(terminal: GhosttyTerminal, renderState: GhosttyRenderState, cell: CellSize) throws -> Graphics {
        var result = Graphics(cell: cell)
        var storage: GhosttyKittyGraphics?
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &storage) == GHOSTTY_SUCCESS,
              let storage
        else {
            images.removeAll()
            return result
        }
        var handle: GhosttyRenderStateImageIterator? = iterator
        try Ghostty.check(ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_IMAGE_ITERATOR, &handle), .graphics)
        var used = Set<UInt32>()
        var total = 0
        while ghostty_render_state_image_iterator_next(iterator), result.placements.count < maxGraphicsPlacements {
            guard let placement = readPlacement(), placement.protocolKind == GHOSTTY_IMAGE_PROTOCOL_KITTY else { continue }
            let id = placement.image
            if !used.contains(id) {
                guard let image = image(id, generation: placement.generation, storage: storage),
                      total + image.rgba.count <= maxGraphicsBytes
                else { continue }
                total += image.rgba.count
                result.images.append(image)
                used.insert(id)
            }
            guard placement.value.size.cols > 0, placement.value.size.rows > 0,
                  placement.value.source.width > 0, placement.value.source.height > 0
            else { continue }
            result.placements.append(placement.value)
        }
        images = images.filter { used.contains($0.key) }
        result.placements.sort { ($0.z, $0.image, $0.id) < ($1.z, $1.image, $1.id) }
        result.images.sort { $0.id < $1.id }
        return result
    }

    private struct Placement {
        var protocolKind: GhosttyImageProtocol
        var image: UInt32
        var generation: UInt64
        var value: GraphicPlacement
    }

    private func readPlacement() -> Placement? {
        var kind = GHOSTTY_IMAGE_PROTOCOL_KITTY
        var image: UInt32 = 0
        var generation: UInt64 = 0
        var placementID: UInt32 = 0
        var z: Int32 = 0
        var column: Int32 = 0
        var row: Int32 = 0
        var cols: UInt32 = 0
        var rows: UInt32 = 0
        var offsetX: UInt32 = 0
        var offsetY: UInt32 = 0
        var sourceX: UInt32 = 0
        var sourceY: UInt32 = 0
        var sourceWidth: UInt32 = 0
        var sourceHeight: UInt32 = 0
        guard field(GHOSTTY_RENDER_STATE_IMAGE_DATA_PROTOCOL, &kind),
              field(GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_ID, &image),
              field(GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_GENERATION, &generation),
              field(GHOSTTY_RENDER_STATE_IMAGE_DATA_KITTY_PLACEMENT_ID, &placementID),
              field(GHOSTTY_RENDER_STATE_IMAGE_DATA_Z, &z),
              field(GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_COL, &column),
              field(GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_ROW, &row),
              field(GHOSTTY_RENDER_STATE_IMAGE_DATA_GRID_COLS, &cols),
              field(GHOSTTY_RENDER_STATE_IMAGE_DATA_GRID_ROWS, &rows),
              field(GHOSTTY_RENDER_STATE_IMAGE_DATA_CELL_OFFSET_X, &offsetX),
              field(GHOSTTY_RENDER_STATE_IMAGE_DATA_CELL_OFFSET_Y, &offsetY),
              field(GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_X, &sourceX),
              field(GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_Y, &sourceY),
              field(GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_WIDTH, &sourceWidth),
              field(GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_HEIGHT, &sourceHeight)
        else { return nil }
        return Placement(
            protocolKind: kind, image: image, generation: generation,
            value: GraphicPlacement(
                image: image, id: placementID, column: column, row: row,
                offset: (offsetX, offsetY), size: (cols, rows),
                source: (sourceX, sourceY, sourceWidth, sourceHeight), z: z))
    }

    private func field(_ key: GhosttyRenderStateImageData, _ value: UnsafeMutableRawPointer) -> Bool {
        ghostty_render_state_image_get(iterator, key, value) == GHOSTTY_SUCCESS
    }

    private func image(_ id: UInt32, generation: UInt64, storage: GhosttyKittyGraphics) -> GraphicImage? {
        if let cached = images[id], cached.generation == generation { return cached }
        guard let handle = ghostty_kitty_graphics_image(storage, id) else { return nil }
        var width: UInt32 = 0
        var height: UInt32 = 0
        var format = GHOSTTY_KITTY_IMAGE_FORMAT_RGBA
        var pointer: UnsafePointer<UInt8>?
        var length = 0
        guard ghostty_kitty_graphics_image_get(handle, GHOSTTY_KITTY_IMAGE_DATA_WIDTH, &width) == GHOSTTY_SUCCESS,
              ghostty_kitty_graphics_image_get(handle, GHOSTTY_KITTY_IMAGE_DATA_HEIGHT, &height) == GHOSTTY_SUCCESS,
              ghostty_kitty_graphics_image_get(handle, GHOSTTY_KITTY_IMAGE_DATA_FORMAT, &format) == GHOSTTY_SUCCESS,
              ghostty_kitty_graphics_image_get(handle, GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR, &pointer) == GHOSTTY_SUCCESS,
              ghostty_kitty_graphics_image_get(handle, GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN, &length) == GHOSTTY_SUCCESS,
              let pointer
        else { return nil }
        let pixels = Int(width) * Int(height)
        guard pixels > 0, pixels * 4 <= maxGraphicsBytes,
              let rgba = Self.premultipliedRGBA(UnsafeBufferPointer(start: pointer, count: length), pixels: pixels, format: format)
        else { return nil }
        let image = GraphicImage(id: id, generation: generation, width: width, height: height, rgba: rgba)
        images[id] = image
        return image
    }

    private static func premultipliedRGBA(
        _ data: UnsafeBufferPointer<UInt8>, pixels: Int, format: GhosttyKittyImageFormat
    ) -> Data? {
        let channels = switch format {
        case GHOSTTY_KITTY_IMAGE_FORMAT_RGBA: 4
        case GHOSTTY_KITTY_IMAGE_FORMAT_RGB: 3
        case GHOSTTY_KITTY_IMAGE_FORMAT_GRAY_ALPHA: 2
        case GHOSTTY_KITTY_IMAGE_FORMAT_GRAY: 1
        default: 0
        }
        guard channels > 0, data.count == pixels * channels else { return nil }
        var output = Data(count: pixels * 4)
        output.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: UInt8.self)
            for pixel in 0..<pixels {
                let source = pixel * channels
                let (r, g, b, a): (UInt8, UInt8, UInt8, UInt8) = switch channels {
                case 4: (data[source], data[source + 1], data[source + 2], data[source + 3])
                case 3: (data[source], data[source + 1], data[source + 2], 255)
                case 2: (data[source], data[source], data[source], data[source + 1])
                default: (data[source], data[source], data[source], 255)
                }
                let target = pixel * 4
                out[target] = premultiply(r, a)
                out[target + 1] = premultiply(g, a)
                out[target + 2] = premultiply(b, a)
                out[target + 3] = a
            }
        }
        return output
    }

    private static func premultiply(_ channel: UInt8, _ alpha: UInt8) -> UInt8 {
        guard alpha < 255 else { return channel }
        return UInt8((UInt16(channel) * UInt16(alpha) + 127) / 255)
    }
}
