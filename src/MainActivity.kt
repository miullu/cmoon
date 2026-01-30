package com.jetbrains.sample.app

import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { MaterialTheme { EpubReaderApp() } }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EpubReaderApp() {
    val context = androidx.compose.ui.platform.LocalContext.current
    val scope = rememberCoroutineScope()
    val drawerState = rememberDrawerState(initialValue = DrawerValue.Closed)
    
    // Application State
    var currentBook by remember { mutableStateOf<EpubBook?>(null) }
    var currentChapterIndex by remember { mutableIntStateOf(0) }
    var parsedNodes by remember { mutableStateOf<List<RenderNode>>(emptyList()) }
    var isLoading by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }

    // Helper to load a specific chapter index
    fun loadChapter(index: Int) {
        val book = currentBook ?: return
        if (index < 0 || index >= book.spine.size) return
        
        isLoading = true
        errorMessage = null // Reset errors
        
        scope.launch(Dispatchers.IO) {
            try {
                val path = book.spine[index]
                val nodes = EpubParser.parseChapter(context, book, path)
                withContext(Dispatchers.Main) {
                    parsedNodes = nodes
                    currentChapterIndex = index
                    isLoading = false
                    // Close drawer if open
                    if (drawerState.isOpen) drawerState.close()
                }
            } catch (e: Exception) {
                e.printStackTrace()
                withContext(Dispatchers.Main) {
                    errorMessage = "Failed to load chapter: ${e.message}"
                    isLoading = false
                }
            }
        }
    }

    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        uri?.let {
            isLoading = true
            errorMessage = null
            parsedNodes = emptyList()
            currentBook = null
            
            scope.launch(Dispatchers.IO) {
                try {
                    val book = EpubParser.openBook(context, it)
                    if (book.spine.isEmpty()) throw Exception("Empty Spine")
                    
                    withContext(Dispatchers.Main) {
                        currentBook = book
                        loadChapter(0) // Load first chapter
                    }
                } catch (e: Exception) {
                    e.printStackTrace()
                    withContext(Dispatchers.Main) {
                        errorMessage = "Error opening book: ${e.message}"
                        isLoading = false
                    }
                }
            }
        }
    }

    ModalNavigationDrawer(
        drawerState = drawerState,
        drawerContent = {
            ModalDrawerSheet {
                Spacer(Modifier.height(12.dp))
                Text("Chapters", modifier = Modifier.padding(16.dp), style = MaterialTheme.typography.titleMedium)
                HorizontalDivider()
                currentBook?.let { book ->
                    LazyColumn {
                        items(book.spine.size) { index ->
                            NavigationDrawerItem(
                                label = { Text("Chapter ${index + 1}") },
                                selected = index == currentChapterIndex,
                                onClick = { loadChapter(index) },
                                modifier = Modifier.padding(NavigationDrawerItemDefaults.ItemPadding)
                            )
                        }
                    }
                }
            }
        }
    ) {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = { Text(currentBook?.title ?: "Amper Reader") },
                    navigationIcon = {
                        if (currentBook != null) {
                            IconButton(onClick = { scope.launch { drawerState.open() } }) {
                                Icon(Icons.Default.Menu, "Menu")
                            }
                        }
                    },
                    actions = {
                        IconButton(onClick = { launcher.launch(arrayOf("application/epub+zip")) }) {
                            Icon(Icons.Default.Add, "Open File")
                        }
                    }
                )
            },
            bottomBar = {
                if (currentBook != null) {
                    BottomAppBar {
                        IconButton(
                            onClick = { loadChapter(currentChapterIndex - 1) },
                            enabled = currentChapterIndex > 0
                        ) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, "Previous")
                        }
                        Spacer(Modifier.weight(1f))
                        Text("Page ${currentChapterIndex + 1} / ${currentBook?.spine?.size ?: 0}")
                        Spacer(Modifier.weight(1f))
                        IconButton(
                            onClick = { loadChapter(currentChapterIndex + 1) },
                            enabled = (currentBook != null) && (currentChapterIndex < currentBook!!.spine.size - 1)
                        ) {
                            Icon(Icons.AutoMirrored.Filled.ArrowForward, "Next")
                        }
                    }
                }
            }
        ) { padding ->
            Box(modifier = Modifier.padding(padding).fillMaxSize(), contentAlignment = Alignment.Center) {
                when {
                    isLoading -> CircularProgressIndicator()
                    errorMessage != null -> Text(errorMessage!!, color = MaterialTheme.colorScheme.error)
                    currentBook == null -> Text("Tap + to open an EPUB file")
                    parsedNodes.isEmpty() -> {
                        // Crucial for debugging: If chapter loads but is blank
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text("Empty Chapter", style = MaterialTheme.typography.titleMedium)
                            Text("(Path: ${currentBook!!.spine[currentChapterIndex]})", style = MaterialTheme.typography.bodySmall)
                        }
                    }
                    else -> {
                        LazyColumn(contentPadding = PaddingValues(16.dp)) {
                            item { ChapterRenderer(parsedNodes, currentBook!!.uri) }
                            item { 
                                Spacer(modifier = Modifier.height(40.dp))
                                Text("--- End of Chapter ---", 
                                    style = MaterialTheme.typography.labelSmall, 
                                    modifier = Modifier.fillMaxWidth().wrapContentWidth(Alignment.CenterHorizontally)) 
                            }
                        }
                    }
                }
            }
        }
    }
}
