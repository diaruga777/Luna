//
//  ArticleIngestProcessor.swift
//  LunaArticleIngest
//

import LunaFetch
import LunaHTMLClassification
import LunaIngest
import LunaModels
import LunaPaywallBypass
import Foundation

/// The article-kind pipeline processor. Resolves a fetched page into a
/// readable article through the direct fetch plus the gated silent bypass
/// strategies (`ArticleResolver`/`BypassPlan`). Article-handling targets'
/// composition roots (Reader, the central Luna app, and their extensions)
/// register this into `IngestKindProcessors.article`. Everywhere else, the
/// pipeline reports the article kind unsupported without carrying any of this
/// code.
public final class ArticleIngestProcessor: ArticleIngestProcessing {
    private let extractor: ArticleExtractor
    private let runner: BypassRunning?

    /// `extractor` and `runner` are test seams; production uses the defaults.
    public init(extractor: ArticleExtractor = ArticleExtractor(), runner: BypassRunning? = nil) {
        self.extractor = extractor
        self.runner = runner
    }

    public func process(
        url: URL, directHTML: String?, trustsPrefetchedHTML: Bool, fetcher: HTMLFetching
    ) async -> Outcome {
        let resolution = await ArticleResolver.resolve(
            url: url, prefetchedHTML: directHTML, fetcher: fetcher,
            extractor: extractor, runner: runner,
            trustsPrefetchedHTML: trustsPrefetchedHTML)

        switch resolution {
        case let .readable(content, html):
            return .article(content, html: html)
        case let .paywalled(title):
            return .needsArchive(title: title)
        case let .unreadable(reason):
            // A browser-only site rule means the background fetch is not the
            // final authority. Anti-bot front doors such as Reuters or
            // DataDome can reject URLSession before yielding even a title,
            // while the rule's direct-unlock WKWebView leg (the same
            // script-blocking path the Safari extension uses) can still
            // render the article. This preserves that route instead of
            // marking the item failed before the browser tier gets a chance
            // to run.
            //
            // Passing `reason` on lets a ruleless host earn the same route: a
            // 401/403/429 refusal turned the client away without saying
            // anything about the page, and a WKWebView is a different
            // client. A plain unreachable page still fails.
            let hasBrowserRecovery = !BypassPlan.make(
                for: url, directHTML: directHTML, directFailure: reason
            ).webPreStages.isEmpty
            // A hard-paywall host or an already-archived URL is likewise
            // still readable behind a user-solved CAPTCHA. Only a truly
            // unreachable ordinary page with no eligible browser recovery is
            // a genuine failure.
            if hasBrowserRecovery || ArticleFetcher.isHardPaywallHost(url)
                || ArticleFetcher.isArchiveTodayURL(url) {
                return .needsArchive(title: ArticleFetcher.articleTitleGuess(from: url))
            }
            return .failed(reason)
        }
    }
}
