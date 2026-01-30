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
            parseOpf(uri, stream, opfPath)
        } ?: throw Exception("OPF file not found")
    }

    private fun parseOpf(uri: Uri, stream: InputStream, opfPath: String): EpubBook {
        val parser = Xml.newPullParser().apply { setInput(stream, null) }
        val manifest = mutableMapOf<String, String>()
        val spineRefs = mutableListOf<String>()
        var title = "Unknown Title"
        val basePath = if (opfPath.contains("/")) opfPath.substringBeforeLast("/") + "/" else ""

        while (parser.next() != XmlPullParser.END_DOCUMENT) {
            if (parser.eventType == XmlPullParser.START_TAG) {
                when (parser.name) {
                    "title", "dc:title" -> title = parser.nextText()
                    "item" -> {
                        val id = parser.getAttributeValue(null, "id")
                        val href = parser.getAttributeValue(null, "href")
                        if (id != null && href != null) {
                            val decoded = URLDecoder.decode(href, "UTF-8")
                            // Store the raw relative path relative to OPF
                            manifest[id] = canonicalizePath(opfPath, decoded) 
                        }
                    }
                    "itemref" -> spineRefs.add(parser.getAttributeValue(null, "idref"))
                }
            }
        }
        val spine = spineRefs.mapNotNull { manifest[it] }
        return EpubBook(uri, title, spine, manifest)
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
                        "div", "body" -> nodes.add(RenderNode.Block(BlockType.Div, extractText(parser)))
                        "img", "image" -> {
                            val src = parser.getAttributeValue(null, "src") 
                                ?: parser.getAttributeValue(null, "href") // for svg image
                            src?.let {
                                val cleanSrc = URLDecoder.decode(it, "UTF-8")
                                // Use the canonicalize helper to fix "../" paths
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
