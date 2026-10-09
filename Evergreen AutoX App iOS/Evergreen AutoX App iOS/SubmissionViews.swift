import PhotosUI
import SwiftUI

struct ProofPhotoBox: View {
    @Binding var proof: Data?
    @State private var item: PhotosPickerItem?
    @State private var preview: UIImage?
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PROOF PHOTO")
                        .egFont(11, weight: .heavy)
                        .kerning(1)
                    Text("A TrackAddict screenshot or a photo of the timing device showing this time. Only the app's maintainer sees it, and it is deleted once reviewed.")
                        .egFont(10.5)
                        .foregroundStyle(Color.egGrayDark)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                PhotosPicker(selection: $item, matching: .images) {
                    if loading {
                        ProgressView().frame(minWidth: 60)
                    } else {
                        Text(proof == nil ? "CHOOSE PHOTO" : "REPLACE")
                    }
                }
                .buttonStyle(EGChipButtonStyle(tint: .egRed))
                .disabled(loading)
            }
            if let preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .frame(maxWidth: .infinity)
                    .overlay(Rectangle().strokeBorder(Color.egDivider, lineWidth: 1))
            }
            if failed {
                EGErrorText(text: "That photo could not be loaded. If it is still in iCloud, open it in Photos first, or pick another one.")
            }
        }
        .padding(12)
        .background(Color.egCard)
        .overlay(Rectangle().strokeBorder(Color.egDivider, lineWidth: 2))
        .onChange(of: item) { _, item in
            guard let item else { return }
            Task { await load(item) }
        }
        .onAppear {
            if preview == nil, let proof { preview = UIImage(data: proof) }
        }
    }

    private func load(_ item: PhotosPickerItem) async {
        loading = true
        failed = false
        defer { loading = false }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let jpeg = Self.jpeg(image)
        else {
            failed = true
            return
        }
        proof = jpeg
        preview = UIImage(data: jpeg)
    }

    // Redrawing the photo is what strips its location and camera metadata,
    // so the original bytes must never be uploaded as they are.
    private static func jpeg(_ image: UIImage) -> Data? {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, 1600 / longest)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.7) { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

struct ProofModeButton: View {
    @Binding var manual: Bool

    var body: some View {
        Button(manual ? "USE A TRACKADDICT LOG" : "NO LOG? USE A PHOTO") {
            manual.toggle()
        }
        .buttonStyle(EGChipButtonStyle())
    }
}

struct ProofReviewNote: View {
    var body: some View {
        Text("The app's maintainer checks the photo before the time appears on the leaderboard.")
            .egFont(10.5)
            .foregroundStyle(Color.egGrayDark)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// The poster's own times that are waiting for review or were turned down,
// for one board. A nil course is the acceleration board.
struct SubmissionsBox: View {
    @Environment(AppModel.self) private var model
    let courseID: Int?
    @State private var error: String?

    private var submissions: [Submission] {
        model.submissions.filter { $0.courseID == courseID && $0.isRun == (courseID != nil) }
    }

    var body: some View {
        if !submissions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(submissions) { submission in
                    row(submission)
                        .overlay(alignment: .top) {
                            if submission.id != submissions.first?.id { Color.egHairline.frame(height: 1) }
                        }
                }
                if let error {
                    EGErrorText(text: error)
                        .padding(10)
                }
            }
            .background(Color.egCard)
            .overlay(Rectangle().strokeBorder(Color.egDivider, lineWidth: 2))
        }
    }

    private func row(_ submission: Submission) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                if submission.rejected {
                    EGTag(text: "NOT APPROVED", background: .egInk, foreground: .egBg, size: 9.5)
                } else {
                    EGOutlineTag(text: "WAITING FOR REVIEW")
                }
                Text(submission.summary)
                    .egFont(12.5, weight: .semibold)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                if let note = submission.reviewNote {
                    Text(note)
                        .egFont(11)
                        .foregroundStyle(Color.egGrayDark)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(submission.rejected ? "DISMISS" : "WITHDRAW") {
                Task {
                    do {
                        try await model.deleteSubmission(id: submission.id)
                        error = nil
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
            .buttonStyle(EGChipButtonStyle())
        }
        .padding(10)
    }
}
