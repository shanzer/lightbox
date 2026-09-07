import Testing
@testable import LightboxCore

@Test func recognizesExtensionsCaseInsensitively() {
    #expect(MediaType.forExtension("JPG")?.kind == .jpeg)
    #expect(MediaType.forExtension("jpeg")?.kind == .jpeg)
    #expect(MediaType.forExtension(".PNG")?.kind == .png)
    #expect(MediaType.forExtension("HEIC")?.kind == .heic)
    #expect(MediaType.forExtension("cr2")?.kind == .raw)
    #expect(MediaType.forExtension("nef")?.kind == .raw)
    #expect(MediaType.forExtension("arw")?.kind == .raw)
    #expect(MediaType.forExtension("dng")?.kind == .raw)
}

@Test func rejectsUnsupportedExtensions() {
    #expect(MediaType.forExtension("txt") == nil)
    #expect(MediaType.forExtension("") == nil)
    #expect(MediaType.forExtension("mov") == nil)   // video is out of scope
}

@Test func reportsImageHashSupportPerFormat() {
    #expect(MediaType.forExtension("jpg")?.imageHashKind == "jpeg-scan-v1")
    #expect(MediaType.forExtension("png")?.imageHashKind == "png-idat-v1")
    #expect(MediaType.forExtension("webp")?.imageHashKind == "webp-chunk-v1")
    #expect(MediaType.forExtension("heic")?.imageHashKind == "heic-item-v1")
    #expect(MediaType.forExtension("heif")?.imageHashKind == "heic-item-v1")
    // NULL in v1: see the spec's hashing section for why each is excluded.
    #expect(MediaType.forExtension("gif")?.imageHashKind == nil)
    #expect(MediaType.forExtension("tif")?.imageHashKind == nil)
    #expect(MediaType.forExtension("cr2")?.imageHashKind == nil)
    #expect(MediaType.forExtension("psd")?.imageHashKind == nil)
}
