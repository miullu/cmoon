package cmoon

import android.net.Uri
import androidx.compose.ui.text.AnnotatedString

data class EpubBook(
    val uri: Uri,
    val title: String,
    val spine: List<String>,
    val manifest: Map<String, String>,
    val toc: List<TOCItem> = emptyList()
)

data class TOCItem(
    val title: String,
    val href: String // This is the path to the file, often including a #fragment
)

sealed class RenderNode {
    data class Text(val content: AnnotatedString) : RenderNode()
    data class Image(val href: String) : RenderNode()
}
