// XDOMSelectors.swift
import Foundation

enum XDOMSelectors {
    // Script to extract current user's profile link (used for login validation)
    static let profileLinkScript: String = """
        (function() {
            // Try to find user handle from various sources
            const sources = [
                // From profile menu
                document.querySelector('a[data-testid="AppTabBar_Profile_Link"]')?.getAttribute('href'),
                // From avatar
                document.querySelector('div[data-testid="UserAvatar"]')?.closest('a')?.getAttribute('href'),
                // From any link that looks like /@username
                Array.from(document.querySelectorAll('a[href^="/"]')).find(a => {
                    const href = a.getAttribute('href') || '';
                    return href.match(/^\\/[a-zA-Z0-9_]+$/);
                })?.getAttribute('href')
            ];

            for (const src of sources) {
                if (src) {
                    const match = src.match(/^\\/([a-zA-Z0-9_]+)$/);
                    if (match && match[1]) {
                        return match[1];
                    }
                }
            }
            return '';
        })();
        """

    // Main tweet extraction script - comprehensive approach
    static func tweetExtractionScript(maxTweets: Int = 20) -> String {
        """
        (function() {
            console.log('[XRadar] Starting tweet extraction...');
            const tweets = [];

            // Try multiple container selectors
            const containerSelectors = [
                'article[data-testid="tweet"]',
                'article',
                '[data-testid="cellInnerDiv"] article',
                'div[data-testid="tweet"]'
            ];

            let containers = [];
            for (const selector of containerSelectors) {
                containers = document.querySelectorAll(selector);
                console.log('[XRadar] Selector "' + selector + '" found: ' + containers.length);
                if (containers.length > 0) break;
            }

            if (containers.length === 0) {
                console.log('[XRadar] No containers found, dumping structure...');
                // Log what we can find
                console.log('Articles: ' + document.querySelectorAll('article').length);
                console.log('data-testid="tweet": ' + document.querySelectorAll('[data-testid="tweet"]').length);
                return JSON.stringify([]);
            }

            for (let i = 0; i < Math.min(containers.length, \(maxTweets)); i++) {
                const container = containers[i];
                try {
                    // Extract tweet ID
                    let tweetId = null;
                    let tweetUrl = null;

                    // Prefer the permalink that owns the article timestamp. A
                    // reply/conversation card can contain links to several
                    // other tweets, while its <time> link identifies the
                    // article itself.
                    const timeLink = container.querySelector('time')?.closest('a[href*="/status/"]');
                    const allLinks = timeLink
                        ? [timeLink]
                        : Array.from(container.querySelectorAll('a[href*="/status/"]'));
                    for (const link of allLinks) {
                        const href = link.getAttribute('href') || '';
                        const match = href.match(/^\\/([^/]+)\\/status\\/(\\d+)/);
                        if (match) {
                            tweetId = match[2];
                            const authorHandle = match[1];
                            tweetUrl = `https://x.com/${authorHandle}/status/${tweetId}`;
                            break;
                        }
                    }

                    if (!tweetId) {
                        console.log('[XRadar] Container ' + i + ': No tweet ID found');
                        continue;
                    }

                    // Extract text - comprehensive search
                    let text = '';
                    const textElements = container.querySelectorAll('[data-testid="tweetText"], div[lang], span[lang]');
                    for (const el of textElements) {
                        const plainText = (el.innerText || el.textContent || '').trim();
                        const imageText = Array.from(el.querySelectorAll('img[alt]'))
                            .map(img => img.getAttribute('alt') || '')
                            .join('');
                        text = (plainText || imageText).trim();
                        if (text) break;
                    }

                    // The owner segment of the canonical status permalink is
                    // the authoritative author for this article.
                    const authorMatch = tweetUrl.match(/x\\.com\\/([^/]+)\\/status\\//);
                    const author = authorMatch ? authorMatch[1] : 'unknown';

                    // Extract timestamp
                    let timestamp = null;
                    const timeEl = container.querySelector('time');
                    if (timeEl) {
                        timestamp = timeEl.getAttribute('datetime');
                    }

                    console.log('[XRadar] Extracted tweet: ' + tweetId + ' by @' + author);

                    const socialContextText =
                        container.querySelector('[data-testid="socialContext"]')?.textContent || '';
                    const replyingToText =
                        container.querySelector('[data-testid="reply"]')?.textContent ||
                        Array.from(container.querySelectorAll('span')).find(el =>
                            (el.textContent || '').trim().toLowerCase().startsWith('replying to')
                        )?.textContent || null;
                    const isPinned = socialContextText.toLowerCase().includes('pinned');

                    tweets.push({
                        id: tweetId,
                        url: tweetUrl,
                        authorHandle: author,
                        text: text || '[No text]',
                        publishedAt: timestamp,
                        isPinned: isPinned,
                        hasSocialContext: (!isPinned && socialContextText.length > 0) || replyingToText !== null,
                        replyingToText: replyingToText
                    });

                } catch (e) {
                    console.log('[XRadar] Error in container ' + i + ':', e.message);
                }
            }

            console.log('[XRadar] Total extracted: ' + tweets.length);
            return JSON.stringify(tweets);
        })();
        """
    }
}
