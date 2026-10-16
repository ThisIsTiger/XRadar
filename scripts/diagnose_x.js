// Diagnostic script to understand X's current DOM structure
(function() {
    const results = {
        url: location.href,
        timestamp: new Date().toISOString(),
        selectors: {}
    };

    // Test various selectors
    const tests = {
        'article[data-testid="tweet"]': document.querySelectorAll('article[data-testid="tweet"]').length,
        'article': document.querySelectorAll('article').length,
        '[data-testid="tweet"]': document.querySelectorAll('[data-testid="tweet"]').length,
        '[data-testid="cellInnerDiv"]': document.querySelectorAll('[data-testid="cellInnerDiv"]').length,
        'div[data-testid="tweetText"]': document.querySelectorAll('div[data-testid="tweetText"]').length,
        'a[href*="/status/"]': document.querySelectorAll('a[href*="/status/"]').length,
        'time': document.querySelectorAll('time').length,
        'nav': document.querySelectorAll('nav').length
    };

    results.selectors = tests;

    // Try to find first tweet structure
    const firstArticle = document.querySelector('article');
    if (firstArticle) {
        results.firstArticleHTML = firstArticle.outerHTML.substring(0, 500);
    }

    console.log('[XRadar Diagnostics]', JSON.stringify(results, null, 2));
    return results;
})();
