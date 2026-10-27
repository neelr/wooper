import UIKit
import UniformTypeIdentifiers

/// "Save to Papery" share-sheet target. Grabs the shared URL and POSTs it to
/// the Papery API, then dismisses with a brief confirmation. Codeless (no
/// storyboard) — wired via NSExtensionPrincipalClass in Info.plist.
@objc(ShareViewController)
final class ShareViewController: UIViewController {

    private let card = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        setupCard()
        extractURL { [weak self] url in
            guard let self else { return }
            guard let url else { self.finish(message: "No link found", ok: false); return }
            Task {
                do {
                    try await PaperyService.save(url: url.absoluteString, title: self.sharedTitle)
                    await MainActor.run { self.finish(message: "Saved to Papery", ok: true) }
                } catch {
                    await MainActor.run { self.finish(message: "Save failed", ok: false) }
                }
            }
        }
    }

    private var sharedTitle: String?

    private func setupCard() {
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = UIColor.secondarySystemBackground
        card.layer.cornerRadius = 16
        view.addSubview(card)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        card.addSubview(spinner)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Saving to Papery…"
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .label
        card.addSubview(label)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.heightAnchor.constraint(equalToConstant: 56),

            spinner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            spinner.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            label.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            label.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
    }

    private func extractURL(_ completion: @escaping (URL?) -> Void) {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let providers = item.attachments
        else { completion(nil); return }

        sharedTitle = item.attributedContentText?.string

        let urlType = UTType.url.identifier
        for provider in providers where provider.hasItemConformingToTypeIdentifier(urlType) {
            provider.loadItem(forTypeIdentifier: urlType, options: nil) { data, _ in
                DispatchQueue.main.async {
                    completion(data as? URL ?? (data as? String).flatMap(URL.init(string:)))
                }
            }
            return
        }
        completion(nil)
    }

    private func finish(message: String, ok: Bool) {
        spinner.stopAnimating()
        spinner.isHidden = true
        label.text = (ok ? "✓ " : "") + message
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
