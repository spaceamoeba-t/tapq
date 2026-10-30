import Foundation

/// One JSON shape for every file the kernel writes, so a line written here decodes there.
/// `package` so another target in this package can write its files in the same shape.
package enum KernelJSON {
    package static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    package static func decoder() -> JSONDecoder {
        JSONDecoder()
    }
}
