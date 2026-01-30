package com.jetbrains.sample.app

import android.net.Uri

data class EpubBook(
    val uri: Uri,
    val title: String,
    val spine: List<String>,
    val manifest: Map<String, String>,
    // Map from canonicalized href (as stored in spine/manifest) to human-readable title from TOC
    val toc: Map<String, String> = emptyMap()
)

sealed class RenderNode {
    data class Block(val type: BlockType, val children: List<RenderNode>) : RenderNode()
    data class TextNode(val text: String) : RenderNode()
    data class ImageNode(val href: String) : RenderNode()
}

enum class BlockType { Paragraph, Header, Div }
