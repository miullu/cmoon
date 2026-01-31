package cmoon

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Xml
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.sp
import org.apache.commons.compress.archivers.zip.ZipFile
import org.jsoup.Jsoup
import org.jsoup.nodes.Element
import org.jsoup.nodes.Node
import org.jsoup.nodes.TextNode
import org.xmlpull.v1.XmlPullParser
import java.io.FileInputStream
import java.io.InputStream
import java.net.URI
import java.net.URLDecoder

object EpubParser {

    fun openBook(context: Context, uri: Uri): EpubBook {
        return useZip(context, uri) { zipFile ->
            val opfPath = findOpfPath(zipFile) 
                ?: throw Exception("Invalid EPUB: No container.xml found")

            val rawOpfData = useEntry(zipFile, opfPath) { stream ->
                parseOpfData(stream, opfPath)
            } ?: throw Exception("OPF file not found at $opfPath")

            val tocList = rawOpfData.tocPath?.let { tocPath ->
                useEntry(zipFile, tocPath) { stream ->
                    if (tocPath.endsWith(".ncx", ignoreCase = true)) {
                        parseNcxToc(stream, tocPath)
                    } else {
                        parseNavToc(stream, tocPath)
                    }
                }
            } ?: emptyList()

            val spinePaths = rawOpfData.spineRefs.mapNotNull { rawOpfData.manifest[it] }

            EpubBook(
                uri = uri,
                title = rawOpfData.title,
                spine = spinePaths,
                manifest = rawOpfData.manifest,
                toc = tocList
            )
        }
    }

    fun parseChapter(context: Context, book: EpubBook, path: String): List<RenderNode> {
        return useZip(context, book.uri) { zipFile ->
            useEntry(zipFile, path) { stream ->
                val document = Jsoup.parse(stream, "UTF-8", path)
                val nodes = mutableListOf<RenderNode>()
                document.body().childNodes().forEach { node ->
                     nodes.addAll(HtmlToCompose.convert(node, path))
                }
                nodes
            } ?: emptyList()
        }
    }

    fun loadImage(context: Context, uri: Uri, path: String): Bitmap? {
        return useZip(context, uri) { zipFile ->
            useEntry(zipFile, path) { stream ->
                BitmapFactory.decodeStream(stream)
            }
        }
    }

    private object HtmlToCompose {
        fun convert(node: Node, basePath: String): List<RenderNode> {
            val results = mutableListOf<RenderNode>()
            if (node is Element && node.tagName() == "img") {
                val src = node.attr("src").takeIf { it.isNotEmpty() } ?: node.attr("href")
                if (src.isNotEmpty()) {
                    results.add(RenderNode.Image(resolvePath(basePath, src)))
                }
                return results
            }

            val builder = AnnotatedString.Builder()
            val imagesInNode = (node as? Element)?.select("img") ?: emptyList()
            
            if (imagesInNode.isEmpty()) {
                visit(node, emptyList(), builder)
                val text = builder.toAnnotatedString()
                if (text.text.isNotBlank()) {
                    results.add(RenderNode.Text(text.trim()))
                }
            } else {
                node.childNodes().forEach { child ->
                    results.addAll(convert(child, basePath))
                }
            }
            return results
        }

        private fun visit(n: Node, styles: List<SpanStyle>, builder: AnnotatedString.Builder) {
            if (n is TextNode) {
                val start = builder.length
                builder.append(n.text())
                styles.forEach { builder.addStyle(it, start, builder.length) }
            } else if (n is Element) {
                val newStyles = styles.toMutableList()
                when (n.tagName()) {
                    "b", "strong" -> newStyles.add(SpanStyle(fontWeight = FontWeight.Bold))
                    "i", "em" -> newStyles.add(SpanStyle(fontStyle = FontStyle.Italic))
                    "u" -> newStyles.add(SpanStyle(textDecoration = TextDecoration.Underline))
                    "h1" -> newStyles.add(SpanStyle(fontSize = 22.sp, fontWeight = FontWeight.Bold))
                    "h2" -> newStyles.add(SpanStyle(fontSize = 20.sp, fontWeight = FontWeight.Bold))
                }
                n.childNodes().forEach { visit(it, newStyles, builder) }
                if (isBlock(n.tagName())) builder.append("\n")
            }
        }
        
        fun isBlock(tag: String): Boolean = tag in setOf("p", "div", "h1", "h2", "h3", "li")
        fun AnnotatedString.trim(): AnnotatedString {
            val start = text.indexOfFirst { !it.isWhitespace() }.coerceAtLeast(0)
            val end = text.indexOfLast { !it.isWhitespace() }.let { if (it == -1) text.length else it + 1 }
            return if (start >= end) AnnotatedString("") else subSequence(start, end)
        }
    }

    // ============================================================================================
    // Internal Parsing Logic
    // ============================================================================================

    private fun findOpfPath(zipFile: ZipFile): String? {
        return useEntry(zipFile, "META-INF/container.xml") { stream ->
            val parser = Xml.newPullParser()
            parser.setInput(stream, null)
            while (parser.next() != XmlPullParser.END_DOCUMENT) {
                if (parser.eventType == XmlPullParser.START_TAG && parser.name == "rootfile") {
                    return@useEntry parser.getAttributeValue(null, "full-path")
                }
            }
            null
        }
    }

    private fun parseOpfData(stream: InputStream, opfPath: String): RawOpfData {
        val parser = Xml.newPullParser()
        parser.setInput(stream, null)
        var title = "Unknown"
        val manifest = mutableMapOf<String, String>()
        val spineRefs = mutableListOf<String>()
        var spineTocId: String? = null
        var navPath: String? = null
        
        while(parser.next() != XmlPullParser.END_DOCUMENT) {
            if (parser.eventType == XmlPullParser.START_TAG) {
                when(parser.name) {
                    "item" -> {
                        val id = parser.getAttributeValue(null, "id")
                        val href = parser.getAttributeValue(null, "href")
                        val props = parser.getAttributeValue(null, "properties")
                        if (id != null && href != null) {
                            val resolved = resolvePath(opfPath, href)
                            manifest[id] = resolved
                            if (props?.contains("nav") == true) navPath = resolved
                        }
                    }
                    "itemref" -> parser.getAttributeValue(null, "idref")?.let { spineRefs.add(it) }
                    "spine" -> spineTocId = parser.getAttributeValue(null, "toc")
                    "title" -> title = parser.nextText()
                }
            }
        }
        return RawOpfData(title, manifest, spineRefs, navPath ?: manifest[spineTocId])
    }

    // EPUB 2 TOC (.ncx)
    private fun parseNcxToc(stream: InputStream, tocPath: String): List<TOCItem> {
        val items = mutableListOf<TOCItem>()
        val parser = Xml.newPullParser()
        parser.setInput(stream, null)
        var currentTitle = ""
        
        while (parser.next() != XmlPullParser.END_DOCUMENT) {
            if (parser.eventType == XmlPullParser.START_TAG) {
                when (parser.name) {
                    "text" -> currentTitle = parser.nextText()
                    "content" -> {
                        val src = parser.getAttributeValue(null, "src")
                        if (src != null) {
                            items.add(TOCItem(currentTitle, resolvePath(tocPath, src)))
                        }
                    }
                }
            }
        }
        return items
    }

    // EPUB 3 TOC (XHTML <nav>)
    private fun parseNavToc(stream: InputStream, tocPath: String): List<TOCItem> {
        val doc = Jsoup.parse(stream, "UTF-8", "")
        val nav = doc.select("nav[epub:type=toc], nav#toc").first() ?: doc.select("nav").first()
        return nav?.select("a")?.map { a ->
            TOCItem(a.text(), resolvePath(tocPath, a.attr("href")))
        } ?: emptyList()
    }

    private fun resolvePath(baseFile: String, relativeUrl: String): String {
        return try {
            val cleanRelative = URLDecoder.decode(relativeUrl, "UTF-8").substringBefore('#')
            if (cleanRelative.isEmpty()) return baseFile
            val baseDir = baseFile.substringBeforeLast('/', "")
            val combined = if (baseDir.isEmpty()) cleanRelative else "$baseDir/$cleanRelative"
            
            // Basic path normalization (handles ../)
            val parts = combined.split('/')
            val stack = mutableListOf<String>()
            for (part in parts) {
                if (part == "..") { if (stack.isNotEmpty()) stack.removeAt(stack.size - 1) }
                else if (part != "." && part.isNotEmpty()) { stack.add(part) }
            }
            stack.joinToString("/")
        } catch (e: Exception) {
            relativeUrl.substringBefore('#')
        }
    }

    private data class RawOpfData(val title: String, val manifest: Map<String, String>, val spineRefs: List<String>, val tocPath: String?)

    private fun <T> useZip(context: Context, uri: Uri, block: (ZipFile) -> T): T {
        val pfd = context.contentResolver.openFileDescriptor(uri, "r") ?: throw Exception("File fail")
        return pfd.use {
            val channel = FileInputStream(it.fileDescriptor).channel
            ZipFile.builder().setSeekableByteChannel(channel).get().use(block)
        }
    }

    private fun <T> useEntry(zipFile: ZipFile, path: String, action: (InputStream) -> T): T? {
        val entry = zipFile.getEntry(path) ?: return null
        return zipFile.getInputStream(entry).use(action)
    }
}
