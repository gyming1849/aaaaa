import SwiftUI
import PhotosUI
import UIKit
import AVFoundation

// MARK: - Photo picking + upload (web1 §5.2 item 3, web2 §5.9.3, meals §2.1)

/// Photos attached to a meal / food lookup / activity recognition. Picks from the library (multi-select) or the camera,
/// converts everything (HEIC included) to JPEG, uploads the batch in one `POST /uploads`, and keeps the returned ids.
/// At most `limit` (6) photos; extra picks are ignored like the web (`slice(0, 6 − current)`). Removing only drops the id
/// locally (the server has no delete endpoint).
@MainActor @Observable final class PhotoUploadModel {
    private(set) var photos: [UploadedPhoto] = []
    private(set) var isUploading = false
    let limit: Int
    var ids: [String] { photos.map(\.id) }
    var remaining: Int { max(0, limit - photos.count) }
    var canAdd: Bool { !isUploading && remaining > 0 }

    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let onError: @MainActor (String) -> Void
    @ObservationIgnored private var generation = 0

    init(api: APIClient, limit: Int = 6, onError: @escaping @MainActor (String) -> Void) {
        self.limit = min(max(1, limit), APIClient.maxPhotos)
        self.api = api
        self.onError = onError
    }

    /// Library selection → JPEG → upload. Shows an error through `onError` when nothing could be read or the upload fails.
    func add(items: [PhotosPickerItem]) async {
        guard canAdd, !items.isEmpty else { return }
        isUploading = true
        defer { isUploading = false }
        let startedIn = generation
        var jpegs: [Data] = []
        for item in items.prefix(remaining) {
            do {
                guard let raw = try await item.loadTransferable(type: Data.self) else { continue }
                if let jpeg = await Self.transcode(raw) { jpegs.append(jpeg) }
            } catch {
                AppLog.app.notice("photo load failed: \(String(describing: error), privacy: .public)")
            }
        }
        guard startedIn == generation else { return }
        guard !jpegs.isEmpty else { onError(Self.unreadableMessage); return }
        await upload(jpegs, startedIn: startedIn)
    }

    /// Camera capture → JPEG → upload.
    func add(image: UIImage) async {
        guard canAdd else { return }
        isUploading = true
        defer { isUploading = false }
        let startedIn = generation
        guard let jpeg = await Self.transcode(image) else { onError(Self.unreadableMessage); return }
        guard startedIn == generation else { return }
        await upload([jpeg], startedIn: startedIn)
    }

    func remove(id: String) { photos.removeAll { $0.id == id } }

    /// Clears the list and drops any upload still in flight.
    func reset() {
        generation += 1
        photos = []
        isUploading = false
    }

    /// Restores ids saved earlier (e.g. a resumed AI job's context). Unknown ids show the placeholder thumbnail.
    func restore(ids: [String]) {
        generation += 1
        photos = ids.filter(APIClient.isValidPhotoId).prefix(limit).map { UploadedPhoto(id: $0, url: "/api/uploads/\($0)") }
    }

    // MARK: Internals

    static let unreadableMessage = "无法读取所选照片"

    private func upload(_ jpegs: [Data], startedIn: Int) async {
        do {
            let uploaded = try await api.uploadPhotos(jpegs: Array(jpegs.prefix(remaining)))
            guard startedIn == generation else { return }
            for (photo, data) in zip(uploaded, jpegs) { await PhotoCache.shared.store(data, for: photo.id) }
            let fresh = uploaded.filter { p in !photos.contains { $0.id == p.id } }
            photos.append(contentsOf: fresh.prefix(remaining))
        } catch is CancellationError {
            return
        } catch {
            guard startedIn == generation else { return }
            onError(APIError.from(error).message)
        }
    }

    nonisolated private static func transcode(_ data: Data) async -> Data? { ImageTranscoder.jpeg(from: data) }
    nonisolated private static func transcode(_ image: UIImage) async -> Data? { ImageTranscoder.jpeg(from: image) }
}

/// A row of 72×72 thumbnails, each with a round × (`移除照片`), plus a dashed add tile with a camera icon (`添加照片`)
/// that offers 从相册选择 / 拍照. The tile shows a spinner while uploading and disappears at the limit.
struct PhotoUploadStrip: View {
    let model: PhotoUploadModel
    let addLabel: String
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var showCameraDenied = false
    @Environment(\.openURL) private var openURL

    init(model: PhotoUploadModel, addLabel: String = "添加照片") { self.model = model; self.addLabel = addLabel }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.photos) { photo in
                    RemotePhoto(photoId: photo.id, side: 72)
                        .overlay(alignment: .topTrailing) { removeButton(photo.id) }
                }
                if model.isUploading {
                    tile { ProgressView() }
                        .accessibilityLabel("正在上传")
                } else if model.remaining > 0 {
                    addTile
                }
            }
            .padding(.vertical, 6)
            .padding(.trailing, 6)
        }
        .photosPicker(isPresented: $showLibrary, selection: $pickerItems, maxSelectionCount: max(1, model.remaining),
                      selectionBehavior: .ordered, matching: .images)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            Task { await model.add(items: items) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in Task { await model.add(image: image) } }
                .ignoresSafeArea()
        }
        .alert("相机权限已关闭", isPresented: $showCameraDenied) {
            Button("去设置") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
            Button("从相册选择") { showLibrary = true }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请在“设置 → 食迹 → 相机”中允许访问，或改为从相册选择照片。")
        }
    }

    /// Opens the camera, or explains how to allow it when access was denied (the system camera would show a black,
    /// unusable viewfinder). `.notDetermined`: the picker shows the system prompt itself.
    private func openCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized, .notDetermined: showCamera = true
        case .denied, .restricted: showCameraDenied = true
        @unknown default: showCamera = true
        }
    }

    @ViewBuilder private var addTile: some View {
        if CameraPicker.isCameraAvailable {
            Menu {
                Button { showLibrary = true } label: { Label("从相册选择", systemImage: "photo.on.rectangle") }
                Button { openCamera() } label: { Label("拍照", systemImage: "camera") }
            } label: {
                addTileLabel
            }
            .accessibilityLabel(addLabel)
        } else {
            Button { showLibrary = true } label: { addTileLabel }
                .buttonStyle(.plain)
                .accessibilityLabel(addLabel)
        }
    }

    private var addTileLabel: some View {
        tile {
            Image(systemName: "camera")
                .font(.system(size: 22))
                .foregroundStyle(Theme.ink3)
        }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
    }

    private func tile<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack { content() }
            .frame(width: 72, height: 72)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// The 22 pt circle stays where it was; the touch area around it is 44 × 44 (clipped by the scroll view's edge above).
    private func removeButton(_ id: String) -> some View {
        Button { model.remove(id: id) } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.black.opacity(0.6)))
                .padding(11)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: 17, y: -17)
        .accessibilityLabel("移除照片")
    }
}
