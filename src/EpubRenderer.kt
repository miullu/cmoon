package cmoon

import android.net.Uri
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Composable
fun ChapterRenderer(nodes: List<RenderNode>, bookUri: Uri) {
    // We can use a simpler loop now. 
    // Note: This function is called INSIDE a LazyColumn item in MainActivity.
    // If you want granular lazy loading, you should move the LazyColumn *here*
    // or flatten the list in MainActivity. 
    // Given the current MainActivity uses `item { ChapterRenderer(...) }`, 
    // this Column will render the WHOLE chapter at once.
    // **Optimization**: For large chapters, change MainActivity to pass the list to items()
    
    Column(modifier = Modifier.padding(16.dp)) {
        nodes.forEach { node ->
            RenderNodeItem(node, bookUri)
        }
    }
}

@Composable
fun RenderNodeItem(node: RenderNode, bookUri: Uri) {
    when (node) {
        is RenderNode.Text -> {
            // High performance text rendering
            Text(
                text = node.content,
                style = MaterialTheme.typography.bodyLarge,
                modifier = Modifier.padding(bottom = 8.dp)
            )
        }
        is RenderNode.Image -> {
            val context = LocalContext.current
            var imageBitmap by remember { mutableStateOf<androidx.compose.ui.graphics.ImageBitmap?>(null) }
            
            LaunchedEffect(node.href) {
                withContext(Dispatchers.IO) {
                    val bitmap = EpubParser.loadImage(context, bookUri, node.href)
                    if (bitmap != null) imageBitmap = bitmap.asImageBitmap()
                }
            }

            imageBitmap?.let {
                Image(
                    bitmap = it,
                    contentDescription = null,
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = 400.dp)
                        .padding(vertical = 12.dp),
                    contentScale = ContentScale.Fit
                )
            }
        }
    }
}
