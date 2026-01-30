package com.jetbrains.sample.app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Xml
import org.apache.commons.compress.archivers.zip.ZipFile
import org.xmlpull.v1.XmlPullParser
import java.io.FileInputStream
import java.io.InputStream
import java.net.URI
import java.net.URLDecoder

object EpubParser {

    // ============================================================================================
    // Public API
    // ============================================================================================

    fun openBook(context: Context, uri: Uri): EpubBook {
        return useZip(context, uri) { zipFile ->
            // 1. Find the OPF file path from container.xml
            val opfPath = findOpfPath(zipFile) 
                ?: throw Exception("Invalid EPUB: No container.xml found")

            // 2. Parse OPF to get metadata, spine, and TOC location
            val rawOpfData = useEntry(zipFile, opfPath) { stream ->
                parseOpfData(stream, opfPath)
            } ?: throw Exception("OPF file not found at $opfPath")

            // 3. Parse the Table of Contents (TOC) to get Chapter Titles
            val tocMap = rawOpfData.tocPath?.let { tocPath ->
                useEntry(zipFile, tocPath) { stream ->
                    parseToc(stream, tocPath, opfPath)
                }
            } ?: emptyMap()

            // 4. Construct the final book object
            // Map spine IDs to actual file paths
            val spinePaths = rawOpfData.spineRefs.mapNotNull { rawOpfData.manifest[it] }

            EpubBook(
                uri = uri,
                title = rawOpfData.title,
                spine = spinePaths,
                manifest = rawOpfData.manifest,
                toc = tocMap
            )
        }
    }

    fun readFullBook(context: Context, book: EpubBook): List<RenderNode> {
        return useZip(context, book.uri) { zipFile ->
            book.spine.flatMap { path ->
                parseChapterContent(zipFile, path)
            }
        }
    }

    fun parseChapter(context: Context, book: EpubBook, path: String): List<RenderNode> {
        return useZip(context, book.uri) { zipFile ->
            parseChapterContent(zipFile, path)
        }
    }

    fun loadImage(context: Context, uri: Uri, path: String): Bitmap? {
        return useZip(context, uri) { zipFile ->
            useEntry(zipFile, path) { stream ->
                BitmapFactory.decodeStream(stream)
            }
        }
    }

    // ============================================================================================
    // Internal Parsing Logic
    // ============================================================================================

    private data class RawOpfData(
        val title: String,
        val manifest: Map<String, String>, // ID -> Full Path
        val spineRefs: List<String>,       // List of IDs
        val tocPath: String?
    )

    private fun findOpfPath(zipFile: ZipFile): String? {
        return useEntry(zipFile, "META-INF/container.xml") { stream ->
            val parser = createParser(stream)
            parser.forEachEvent {
                if (eventType == XmlPullParser.START_TAG && name == "rootfile") {
                    return@useEntry getAttributeValue(null, "full-path")
                }
            }
            null
        }
    }

    private fun parseOpfData(stream: InputStream, opfPath: String): RawOpfData {
        val parser = createParser(stream)
        
        var title = "Unknown Title"
        val manifest = mutableMapOf<String, String>() // ID -> Resolved Path
        val spineRefs = mutableListOf<String>()
        var spineTocId: String? = null
        var ncxId: String? = null
        var navPath: String? = null

        parser.forEachEvent {
            if (eventType == XmlPullParser.START_TAG) {
                when (name) {
                    "title", "dc:title" -> title = safeNextText()
                    "item" -> {
                        val id = getAttributeValue(null, "id")
                        val href = getAttributeValue(null, "href")
                        val props = getAttributeValue(null, "properties")
                        val mediaType = getAttributeValue(null, "media-type")

                        if (id != null && href != null) {
                            val resolvedPath = resolvePath(opfPath, href)
                            manifest[id] = resolvedPath

                            // Identify TOC candidates
                            if (props?.contains("nav") == true) {
                                navPath = resolvedPath // EPUB 3
                            }
                            if (mediaType == "application/x-dtbncx+xml") {
                                ncxId = id // EPUB 2
                            }
                        }
                    }
                    "spine" -> spineTocId = getAttributeValue(null, "toc")
                    "itemref" -> getAttributeValue(null, "idref")?.let { spineRefs.add(it) }
                }
            }
        }

        // Priority: EPUB 3 Nav -> OPF Spine attribute -> NCX Item in Manifest
        val finalTocPath = navPath ?: manifest[spineTocId] ?: manifest[ncxId]

        return RawOpfData(title, manifest, spineRefs, finalTocPath)
    }

    /**
     * Parses both EPUB 2 (NCX) and EPUB 3 (Nav) TOC formats.
     */
    private fun parseToc(stream: InputStream, tocPath: String, opfPath: String): Map<String, String> {
        val parser = createParser(stream)
        val tocMap = mutableMapOf<String, String>()
        
        // We detect the type based on tags inside the file
        parser.forEachEvent {
            if (eventType == XmlPullParser.START_TAG) {
                when (name.lowercase()) {
                    "navpoint" -> parseNcxNavPoint(this, tocPath, tocMap) // EPUB 2
                    "nav" -> {
                        // EPUB 3: Only parse the 'toc' nav, skip 'page-list' etc.
                        val type = getAttributeValue(null, "epub:type")
                        if (type == null || type == "toc") {
                            parseEpub3Nav(this, tocPath, tocMap)
                        }
                    }
                }
            }
        }
        return tocMap
    }

    private fun parseNcxNavPoint(parser: XmlPullParser, basePath: String, result: MutableMap<String, String>) {
        // <navLabel><text>Title</text></navLabel> <content src="path.html"/>
        var label = ""
        var src = ""

        parser.readTagChildren("navPoint") {
            when (name.lowercase()) {
                "navlabel" -> {
                    parser.readTagChildren("navLabel") {
                        if (name.lowercase() == "text") label = safeNextText()
                    }
                }
                "content" -> src = getAttributeValue(null, "src") ?: ""
                "navpoint" -> parseNcxNavPoint(this, basePath, result) // Recursion for nested TOC
            }
        }

        if (src.isNotEmpty() && label.isNotEmpty()) {
            val fullPath = resolvePath(basePath, src)
            // Store the path without anchor as key to match Spine items later
            result[fullPath] = label
        }
    }

    private fun parseEpub3Nav(parser: XmlPullParser, basePath: String, result: MutableMap<String, String>) {
        // <ol> <li> <a href="path.html">Title</a> </li> </ol>
        // We scan recursively for <a> tags inside the nav
        val depth = parser.depth
        while (!(parser.next() == XmlPullParser.END_TAG && parser.depth == depth)) {
            if (parser.eventType == XmlPullParser.START_TAG && parser.name.lowercase() == "a") {
                val href = parser.getAttributeValue(null, "href")
                val title = parser.safeNextText() // Extracts text content of <a>
                
                if (!href.isNullOrEmpty() && title.isNotEmpty()) {
                    val fullPath = resolvePath(basePath, href)
                    result[fullPath] = title
                }
            }
        }
    }

    private fun parseChapterContent(zipFile: ZipFile, path: String): List<RenderNode> {
        return useEntry(zipFile, path) { stream ->
            val parser = createParser(stream)
            val nodes = mutableListOf<RenderNode>()

            parser.forEachEvent {
                if (eventType == XmlPullParser.START_TAG) {
                    when (name.lowercase()) {
                        in setOf("h1", "h2", "h3", "h4", "h5", "h6") -> 
                            nodes.add(RenderNode.Block(BlockType.Header, extractRichText(this)))
                        "p" -> 
                            nodes.add(RenderNode.Block(BlockType.Paragraph, extractRichText(this)))
                        "img", "image" -> {
                            val href = getAttributeValue(null, "src") ?: getAttributeValue(null, "href")
                            href?.let {
                                nodes.add(RenderNode.ImageNode(resolvePath(path, it)))
                            }
                        }
                    }
                }
            }
            nodes
        } ?: emptyList()
    }

    /**
     * Extracts text mixed with simple inline tags (like <b>, <i>, <img>).
     * Returns a list because a paragraph might contain an ImageNode inline.
     */
    private fun extractRichText(parser: XmlPullParser): List<RenderNode> {
        val nodes = mutableListOf<RenderNode>()
        val startDepth = parser.depth
        val sb = StringBuilder()

        while (parser.next() != XmlPullParser.END_DOCUMENT) {
            if (parser.eventType == XmlPullParser.END_TAG && parser.depth == startDepth) break
            
            when (parser.eventType) {
                XmlPullParser.TEXT -> sb.append(parser.text)
                XmlPullParser.START_TAG -> {
                    if (parser.name.lowercase() == "img") {
                        // Flush accumulated text first
                        if (sb.isNotBlank()) {
                            nodes.add(RenderNode.TextNode(sb.toString().cleanWhitespace()))
                            sb.clear()
                        }
                        val src = parser.getAttributeValue(null, "src")
                        if (src != null) nodes.add(RenderNode.ImageNode(src))
                    }
                }
                XmlPullParser.END_TAG -> sb.append(" ") // Add space on end tags of inline elements like </span>
            }
        }
        
        if (sb.isNotBlank()) {
            nodes.add(RenderNode.TextNode(sb.toString().cleanWhitespace()))
        }
        return nodes
    }

    // ============================================================================================
    // Helpers: Path & Strings
    // ============================================================================================

    /**
     * ELEGANT PATH RESOLUTION: Uses java.net.URI
     * 
     * @param baseFile The file (e.g., "OEBPS/content.opf") the relative path is inside.
     * @param relativeUrl The link found in the file (e.g., "../Images/cover.jpg" or "chap1.html#anchor").
     */
    private fun resolvePath(baseFile: String, relativeUrl: String): String {
        try {
            // 1. Decode URL (Turn "%20" back into " ")
            val decodedRelative = URLDecoder.decode(relativeUrl, "UTF-8")
            
            // 2. Remove anchors (#part1) as ZipEntry names don't have them
            val cleanRelative = decodedRelative.substringBefore('#')
            if (cleanRelative.isEmpty()) return baseFile // It was just an anchor to the same file

            // 3. Resolve using URI
            // We create a dummy "file:///" URI to force absolute path logic, then strip it back.
            // This handles ".." and "." correctly.
            val baseUri = URI.create("file:///$baseFile")
            val resolvedUri = baseUri.resolve(cleanRelative)
            
            // 4. Return path without leading slash (Zip entries usually don't have / at start)
            return resolvedUri.path.removePrefix("/")
        } catch (e: Exception) {
            // Fallback for malformed URIs
            return relativeUrl.substringBefore('#')
        }
    }

    private fun String.cleanWhitespace() = this.replace("\\s+".toRegex(), " ")

    // ============================================================================================
    // Helpers: XML & Zip
    // ============================================================================================

    private fun createParser(stream: InputStream): XmlPullParser {
        return Xml.newPullParser().apply {
            setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, false)
            setInput(stream, null)
        }
    }

    private inline fun XmlPullParser.forEachEvent(block: XmlPullParser.() -> Unit) {
        while (next() != XmlPullParser.END_DOCUMENT) {
            block()
        }
    }

    private inline fun XmlPullParser.readTagChildren(tagName: String, block: XmlPullParser.() -> Unit) {
        val depth = this.depth
        while (!(next() == XmlPullParser.END_TAG && this.depth == depth)) {
            if (eventType == XmlPullParser.START_TAG) {
                block()
            }
        }
    }

    private fun XmlPullParser.safeNextText(): String {
        return if (eventType == XmlPullParser.START_TAG) nextText() else ""
    }

    private fun <T> useZip(context: Context, uri: Uri, block: (ZipFile) -> T): T {
        val pfd = context.contentResolver.openFileDescriptor(uri, "r")
            ?: throw Exception("Cannot open URI: $uri")
        return pfd.use {
            // Use FileChannel for random access (much faster for Zips than streams)
            val channel = FileInputStream(it.fileDescriptor).channel
            ZipFile.builder()
                .setSeekableByteChannel(channel)
                .get()
                .use { zip -> block(zip) }
        }
    }

    private fun <T> useEntry(zipFile: ZipFile, path: String, action: (InputStream) -> T): T? {
        val entry = zipFile.getEntry(path) ?: return null
        return zipFile.getInputStream(entry).use(action)
    }
}
