import Foundation
import CryptoKit
import UniformTypeIdentifiers
import ImageIO
import GRDB
import KongReviewCore

struct EditorMediaFile: Sendable {
    let data: Data
    let name: String
    let mime: String
    let image: Bool
    static func read(_ url: URL,for kind: String) throws -> Self {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey])
        guard size.isRegularFile == true,(size.fileSize ?? 0)>0,(size.fileSize ?? Int.max)<=32*1024*1024 else { throw MediaError.invalidFile }
        let data = try Data(contentsOf:url,options:.mappedIfSafe)
        return try make(data:data,extension:url.pathExtension,for:kind)
    }
    static func make(data: Data,extension ext: String,for kind: String) throws -> Self {
        guard !data.isEmpty,data.count<=32*1024*1024 else { throw MediaError.invalidFile }
        let mime = LocalSchemeHandler.mime(for:"file."+ext.lowercased())
        let image = mime.hasPrefix("image/")
        if kind == "图片" {
            guard image,let source = CGImageSourceCreateWithData(data as CFData,nil),CGImageSourceGetCount(source)>0,CGImageSourceCreateImageAtIndex(source,0,nil) != nil else { throw MediaError.invalidImage }
        } else { guard mime.hasPrefix("audio/") || mime.hasPrefix("video/") else { throw MediaError.invalidFile } }
        let hash = SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
        return .init(data:data,name:"editor-"+hash+"."+ext.lowercased(),mime:mime,image:image)
    }
    var previewHTML: String {
        let src = "data:"+mime+";base64,"+data.base64EncodedString()
        return image ? "<img src=\""+src+"\">" : "<"+(mime.hasPrefix("video/") ? "video" : "audio")+" controls src=\""+src+"\"></"+(mime.hasPrefix("video/") ? "video" : "audio")+">"
    }
    enum MediaError: LocalizedError {
        case invalidFile,invalidImage,changed
        var errorDescription: String? { switch self { case .invalidFile:"请选择有效的图片、音频或视频文件，大小不超过32MB。";case .invalidImage:"这个文件不能解码为图片，请重新选择。";case .changed:"当前正文或媒体引用已变化，请重新打开检查。" } }
    }
}
extension AppDatabase {
    func saveEditorMedia(_ file: EditorMediaFile) async throws {
        try await writer.write { db in
            if let old = try Data.fetchOne(db,sql:"SELECT data FROM card_media WHERE name=?",arguments:[file.name]),old != file.data { throw EditorMediaFile.MediaError.changed }
            try db.execute(sql:"INSERT OR IGNORE INTO card_media(name,data) VALUES(?,?)",arguments:[file.name,file.data])
        }
    }
}
extension RichEditorHandle {
    func replaceMedia(_ reference: EditorResourceReference,in source: String,baseline: String,file: EditorMediaFile,db: AppDatabase,completion: @escaping (Bool)->Void) {
        guard valueReader?() == baseline,NSMaxRange(reference.range)<=(source as NSString).length else { completion(false); return }
        let name = file.name
        let sound = reference.kind == "音频"
        let address = sound ? name : "kr-media://media/"+name
        let proposed = (source as NSString).replacingCharacters(in:reference.range,with:HTMLSourceCodec.attribute(address))
        snapshot { [weak self] actual,sourceMode in
            guard let self,let actual,self.valueReader?() == baseline else { completion(false); return }
            if sourceMode && actual != source { completion(false); return }
            Task { @MainActor in
                do {
                    try await db.saveEditorMedia(file)
                    guard self.valueReader?() == baseline else { completion(false); return }
                    let value = sourceMode ? proposed : EditorPage.displayHTML(for:proposed,mode:.card).html
                    self.apply(.init(title:"替换媒体",original:actual,proposed:value,count:1,source:sourceMode,storedBaseline:baseline),completion:completion)
                } catch { self.findError = error.localizedDescription; completion(false) }
            }
        }
    }
}
