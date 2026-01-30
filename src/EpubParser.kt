package com.jetbrains.sample.app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Xml
import org.xmlpull.v1.XmlPullParser
import java.io.InputStream
import java.net.URLDecoder
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream

object EpubParser {

    // Helper to resolve "Text/../Images/icon.png" -> "Images/icon.png"
    private fun canonicalizePath(basePath: String, relativePath: String): String {
        if (relativePath.startsWith("/")) return relativePath.removePrefix("/")

        val baseDir = if (basePath.contains("/")) basePath.substringBeforeLast("/") else ""
        val combined = if (baseDir.isNotEmpty()) "$baseDir/$relativePath" else relativePath

        val parts = combined.split("/")
        val stack = ArrayDeque<String>()

        for (part in parts) {
            when (part) {
                ".", "" -> continue
                ".." -> if (stack.isNotEmpty()) stack.removeLast()
                else -> stack.addLast(part)
            }
        }
        return stack.joinToString("/")
    }

    fun openBook(context: Context, uri: Uri): EpubBook {
        val opfPath = scanForEntry(context, uri, "META-INF/container.xml") { stream ->
            val parser = Xml.newPullParser().apply { setInput(stream, null) }
            var path = ""
            while (parser.next() != XmlPullParser.END_DOCUMENT) {
                if (parser.eventType == XmlPullParser.START_TAG && parser.name == "rootfile") {
                    path = parser.getAttributeValue(null, "full-path")
                }
            }
            path
        } ?: throw Exception("Invalid EPUB: No container.xml")

        return scanForEntry(context, uri, opfPath) { stream ->
            parseOpf(context, uri, stream, opfPath)
        } ?: throw Exception("OPF file not found")
    }

    private fun parseOpf(context: Context, uri: Uri, stream: InputStream, opfPath: String): EpubBook {
        val parser = Xml.newPullParser().apply { setInput(stream, null) }
        val manifest = mutableMapOf<String, String>() // id -> href (canonicalized)
        val mediaTypes = mutableMapOf<String, String?>() // id -> media-type
        val propertiesMap = mutableMapOf<String, String?>() // id -> properties
        val spineRefs = mutableListOf<String>()
        var title = "Unknown Title"
        var spineTocId: String? = null

        while (parser.next() != XmlPullParser.END_DOCUMENT) {
            if (parser.eventType == XmlPullParser.START_TAG) {
                when (parser.name) {
                    "title", "dc:title" -> title = parser.nextText()
                    "item" -> {
                        val id = parser.getAttributeValue(null, "id")
                        val href = parser.getAttributeValue(null, "href")
                        val mediaType = parser.getAttributeValue(null, "media-type")
                        val properties = parser.getAttributeValue(null, "properties")
                        if (id != null && href != null) {
                            val decoded = URLDecoder.decode(href, "UTF-8")
                            manifest[id] = canonicalizePath(opfPath, decoded)
                            mediaTypes[id] = mediaType
                            propertiesMap[id] = properties
                        }
                    }
                    "spine" -> {
                        val toc = parser.getAttributeValue(null, "toc")
                        if (!toc.isNullOrEmpty()) spineTocId = toc
                    }
                    "itemref" -> {
                        val idref = parser.getAttributeValue(null, "idref")
                        if (idref != null) spineRefs.add(idref)
                    }
                }
            }
        }

        val spine = spineRefs.mapNotNull { manifest[it] }

        // Try to locate TOC: prefer spine@toc -> NCX by media-type -> manifest item with properties 'nav'
        var tocPath: String? = null
        if (spineTocId != null) tocPath = manifest[spineTocId]
        if (tocPath == null) {
            val ncxId = mediaTypes.entries.firstOrNull { it.value == "application/x-dtbncx+xml" }?.key
            if (ncxId != null) tocPath = manifest[ncxId]
        }
        if (tocPath == null) {
            val navId = propertiesMap.entries.firstOrNull { it.value?.contains("nav") == true }?.key
            if (navId != null) tocPath = manifest[navId]
        }

        // Build TOC map href -> title (canonicalized href => title)
        val tocMap = if (tocPath != null) {
            parseToc(context, uri, tocPath, opfPath)
        } else {
            emptyMap()
        }

        return EpubBook(uri, title, spine, manifest, tocMap)
    }

    private fun parseToc(context: Context, uri: Uri, tocPath: String, opfPath: String): Map<String, String> {
        // scanForEntry reads the file from ZIP and parses it
        return scanForEntry(context, uri, tocPath) { stream ->
            val parser = Xml.newPullParser().apply {
                setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, false)
                setInput(stream, null)
            }

            // Decide whether it's NCX (EPUB2) or XHTML nav (EPUB3)
            // NCX root element usually is "ncx" or has namespace with "ncx"
            // We'll look at first start tag
            var isNcx = false
            // advance to first start tag
            while (parser.next() != XmlPullParser.END_DOCUMENT) {
                if (parser.eventType == XmlPullParser.START_TAG) {
                    val name = parser.name.lowercase()
                    isNcx = name == "ncx"
                    break
                }
            }

            val result = mutableMapOf<String, String>()
            if (isNcx) {
                // reset isn't available; we already consumed the start tag. It's OK — continue parsing navMap.
                // We'll parse navPoint elements for title (navLabel/text) and content/@src
                // We assume parser is currently at the ncx start tag (we consumed it)
                var depth = 1
                var currentTitle: String? = null
                while (depth > 0 && parser.next() != XmlPullParser.END_DOCUMENT) {
                    when (parser.eventType) {
                        XmlPullParser.START_TAG -> {
                            depth++
                            val tag = parser.name.lowercase()
                            if (tag == "navpoint") {
                                currentTitle = null
                            } else if (tag == "text" && currentTitle == null) {
                                // read title
                                currentTitle = parser.nextText().trim()
                            } else if (tag == "content") {
                                val src = parser.getAttributeValue(null, "src")
                                if (!src.isNullOrEmpty()) {
                                    val hrefClean = src.substringBefore('#')
                                    val resolved = canonicalizePath(opfPath, URLDecoder.decode(hrefClean, "UTF-8"))
                                    if (currentTitle != null) {
                                        result[resolved] = currentTitle
                                    } else {
                                        // if title not found before content, try to find later, but store placeholder
                                        result[resolved] = result[resolved] ?: ""
                                    }
                                }
                            }
                        }
                        XmlPullParser.END_TAG -> depth--
                    }
                }
            } else {
                // Try EPUB3 nav XHTML parsing: find <nav ... epub:type="toc"> and then <a href="...">Text</a>
                // We'll do a simple heuristic: set inNav when encountering <nav> and unset at its end.
                var inNav = false
                var depth = 0
                // parser may have already read first start tag (not ncx), but we'll continue parsing
                while (parser.eventType != XmlPullParser.END_DOCUMENT) {
                    when (parser.eventType) {
                        XmlPullParser.START_TAG -> {
                            val tag = parser.name.lowercase()
                            if (tag == "nav") {
                                // check attributes or accept first nav as fallback
                                val epubType = parser.getAttributeValue(null, "epub:type") ?: parser.getAttributeValue(null, "type")
                                if (epubType == "toc" || epubType == "toc" || epubType.isNullOrEmpty()) {
                                    inNav = true
                                }
                                depth++
                            } else if (inNav && tag == "a") {
                                val src = parser.getAttributeValue(null, "href")
                                val text = parser.nextText().trim()
                                if (!src.isNullOrEmpty()) {
                                    val hrefClean = src.substringBefore('#')
                                    val resolved = canonicalizePath(opfPath, URLDecoder.decode(hrefClean, "UTF-8"))
                                    result[resolved] = text
                                }
                            } else {
                                depth++
                            }
                        }
                        XmlPullParser.END_TAG -> {
                            val tag = parser.name?.lowercase()
                            if (tag == "nav") inNav = false
                            depth--
                        }
                    }
                    if (parser.next() == XmlPullParser.END_DOCUMENT) break
                }
            }
            result
        } ?: emptyMap()
    }

    fun parseChapter(context: Context, book: EpubBook, path: String): List<RenderNode> {
        return scanForEntry(context, book.uri, path) { stream ->
            val parser = Xml.newPullParser().apply {
                setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, false)
                setInput(stream, null)
            }
            val nodes = mutableListOf<RenderNode>()
            while (parser.next() != XmlPullParser.END_DOCUMENT) {
                if (parser.eventType == XmlPullParser.START_TAG) {
                    when (parser.name.lowercase()) {
                        "h1", "h2", "h3", "h4", "h5", "h6" -> nodes.add(RenderNode.Block(BlockType.Header, extractText(parser)))
                        "p" -> nodes.add(RenderNode.Block(BlockType.Paragraph, extractText(parser)))
                        // Do NOT call extractText on body/div here — let the loop enter their children
                        "img", "image" -> {
                            val src = parser.getAttributeValue(null, "src")
                                ?: parser.getAttributeValue(null, "href") // for svg image
                            src?.let {
                                val cleanSrc = URLDecoder.decode(it, "UTF-8")
                                val resolved = canonicalizePath(path, cleanSrc)
                                nodes.add(RenderNode.ImageNode(resolved))
                            }
                        }
                    }
                }
            }
            nodes
        } ?: emptyList()
    }

    fun loadImage(context: Context, uri: Uri, path: String): Bitmap? {
        return scanForEntry(context, uri, path) { stream ->
            BitmapFactory.decodeStream(stream)
        }
    }

    private fun <T> scanForEntry(context: Context, uri: Uri, targetPath: String, action: (InputStream) -> T): T? {
        val inputStream = context.contentResolver.openInputStream(uri) ?: return null
        ZipInputStream(inputStream).use { zipStream ->
            var entry: ZipEntry? = zipStream.nextEntry
            while (entry != null) {
                if (entry.name == targetPath) {
                    return action(zipStream)
                }
                zipStream.closeEntry()
                entry = zipStream.nextEntry
            }
        }
        return null
    }

    private fun extractText(parser: XmlPullParser): List<RenderNode> {
        val result = mutableListOf<RenderNode>()
        var depth = 1
        while (depth > 0 && parser.next() != XmlPullParser.END_DOCUMENT) {
            when (parser.eventType) {
                XmlPullParser.START_TAG -> depth++
                XmlPullParser.END_TAG -> depth--
                XmlPullParser.TEXT -> if (parser.text.isNotBlank()) result.add(RenderNode.TextNode(parser.text.trim()))
            }
        }
        return result
    }
}
