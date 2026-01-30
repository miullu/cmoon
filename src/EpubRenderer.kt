package com.jetbrains.sample.app

import android.content.Context
import android.net.Uri
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Composable
fun ChapterRenderer(nodes: List<RenderNode>, bookUri: Uri) {
    Column(modifier = Modifier.padding(16.dp)) {
        nodes.forEach { node ->
            RenderNodeItem(node, bookUri)
        }
    }
}

@Composable
fun RenderNodeItem(node: RenderNode, bookUri: Uri) {
    val context = LocalContext.current
    
    when (node) {
        is RenderNode.Block -> {
            Column(modifier = Modifier.padding(bottom = 12.dp)) {
                val style = when (node.type) {
                    BlockType.Header -> MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.Bold)
                    BlockType.Paragraph -> MaterialTheme.typography.bodyLarge
                    else -> MaterialTheme.typography.bodyMedium
                }
                val text = node.children.filterIsInstance<RenderNode.TextNode>().joinToString(" ") { it.text }
                if (text.isNotEmpty()) Text(text = text, style = style)
                
                node.children.filter { it !is RenderNode.TextNode }.forEach { RenderNodeItem(it, bookUri) }
            }
        }
        is RenderNode.ImageNode -> {
            // Load Image on demand (requires scanning stream)
            var imageBitmap by remember { mutableStateOf<androidx.compose.ui.graphics.ImageBitmap?>(null) }
            
            LaunchedEffect(node.href) {
                withContext(Dispatchers.IO) {
                    val bitmap = EpubParser.loadImage(context, bookUri, node.href)
                    if (bitmap != null) {
                        imageBitmap = bitmap.asImageBitmap()
                    }
                }
            }

            imageBitmap?.let {
                Image(
                    bitmap = it,
                    contentDescription = null,
                    modifier = Modifier.fillMaxWidth().heightIn(max=300.dp).padding(vertical=8.dp),
                    contentScale = ContentScale.Fit
                )
            }
        }
        is RenderNode.TextNode -> {}
    }
}
