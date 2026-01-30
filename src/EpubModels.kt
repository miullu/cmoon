package com.jetbrains.sample.app

import android.net.Uri

data class EpubBook(
    val uri: Uri,          // We keep the URI to re-open stream on demand
    val title: String,
    val spine: List<String>, 
    val manifest: Map<String, String>
)

sealed class RenderNode {
    data class Block(val type: BlockType, val children: List<RenderNode>) : RenderNode()
    data class TextNode(val text: String) : RenderNode()
    data class ImageNode(val href: String) : RenderNode()
}

enum class BlockType { Paragraph, Header, Div }
