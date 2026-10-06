// 在已加载的网页里运行：用 Readability 提取正文，返回 JSON 字符串（失败返回 "null"）
(function () {
  try {
    var doc = document.cloneNode(true);
    var article = new Readability(doc, { charThreshold: 200, keepClasses: false }).parse();
    if (!article || !article.content) return "null";
    return JSON.stringify({
      title: article.title || document.title || "",
      byline: article.byline || null,
      siteName: article.siteName || null,
      publishedTime: article.publishedTime || null,
      excerpt: article.excerpt || null,
      content: article.content,
      textContent: article.textContent || "",
      length: article.length || 0,
      lang: article.lang || document.documentElement.lang || null,
      h1: (function () { var h = document.querySelector("h1"); return h ? h.textContent.trim() : null; })(),
      url: location.href
    });
  } catch (e) {
    return JSON.stringify({ error: String(e) });
  }
})();
