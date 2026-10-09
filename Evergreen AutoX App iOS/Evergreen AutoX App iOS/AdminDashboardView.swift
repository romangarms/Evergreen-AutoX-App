import SafariServices
import SwiftUI

struct AdminDashboardLink: Identifiable {
    let url: URL
    var id: URL { url }

    // SFSafariViewController raises an exception for anything but http(s).
    init?(baseURLString: String) {
        let base = baseURLString.hasSuffix("/") ? String(baseURLString.dropLast()) : baseURLString
        guard let url = URL(string: "\(base)/dev#submissions"),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host() != nil
        else { return nil }
        self.url = url
    }
}

struct AdminDashboardView: UIViewControllerRepresentable {
    let link: AdminDashboardLink

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: link.url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
