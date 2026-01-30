package com.jetbrains.sample.app

import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge() 
        super.onCreate(savedInstanceState)
        setContent { 
            MaterialTheme { 
                Surface(color = MaterialTheme.colorScheme.background) {
                    EpubReaderApp() 
                }
            } 
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EpubReaderApp() {
    val context = androidx.compose.ui.platform.LocalContext.current
    val scope = rememberCoroutineScope()
    val drawerState = rememberDrawerState(initialValue = DrawerValue.Closed)
    val listState = rememberLazyListState()

    // Application State
    var currentBook by remember { mutableStateOf<EpubBook?>(null) }
    var currentChapterIndex by remember { mutableIntStateOf(0) }
    var parsedNodes by remember { mutableStateOf<List<RenderNode>>(emptyList()) }
    var isLoading by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }

    // UI State for Floating Bar
    var isBarVisible by remember { mutableStateOf(true) }

    // Detect if we are at the end of the list
    val isAtEnd by remember {
        derivedStateOf {
            val layoutInfo = listState.layoutInfo
            val totalItemsNumber = layoutInfo.totalItemsCount
            val lastVisibleItemIndex = (layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0) + 1
            lastVisibleItemIndex >= totalItemsNumber && totalItemsNumber > 0
        }
    }

    // Floating bar visibility logic
    val shouldShowBar by remember {
        derivedStateOf { isBarVisible || isAtEnd || currentBook == null }
    }

    val nestedScrollConnection = remember {
        object : NestedScrollConnection {
            override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
                if (available.y < -5) isBarVisible = false
                if (available.y > 5) isBarVisible = true
                return Offset.Zero
            }
        }
    }

    fun loadChapter(index: Int) {
        val book = currentBook ?: return
        if (index < 0 || index >= book.spine.size) return

        isLoading = true
        errorMessage = null

        scope.launch(Dispatchers.IO) {
            try {
                val path = book.spine[index]
                val nodes = EpubParser.parseChapter(context, book, path)
                withContext(Dispatchers.Main) {
                    parsedNodes = nodes
                    currentChapterIndex = index
                    isLoading = false
                    isBarVisible = true 
                    listState.scrollToItem(0) 
                    if (drawerState.isOpen) drawerState.close()
                }
            } catch (e: Exception) {
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
                    withContext(Dispatchers.Main) {
                        currentBook = book
                        loadChapter(0)
                    }
                } catch (e: Exception) {
                    withContext(Dispatchers.Main) {
                        errorMessage = "Error: ${e.message}"
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
                Text("cmoon", modifier = Modifier.padding(16.dp), style = MaterialTheme.typography.titleMedium)
                HorizontalDivider()
                currentBook?.let { book ->
                    LazyColumn {
                        items(book.spine.size) { index ->
                            val chapterHref = book.spine[index]
                            val chapterTitle = book.toc[chapterHref] ?: "Chapter ${index + 1}"
                            NavigationDrawerItem(
                                label = { Text(chapterTitle) },
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
        Scaffold { padding ->
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .nestedScroll(nestedScrollConnection)
            ) {
                // Content Layer
                when {
                    isLoading -> CircularProgressIndicator(Modifier.align(Alignment.Center))
                    errorMessage != null -> Text(errorMessage!!, color = MaterialTheme.colorScheme.error, modifier = Modifier.align(Alignment.Center))
                    currentBook == null -> {
                        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.align(Alignment.Center)) {
                            Text("cmoon", style = MaterialTheme.typography.headlineSmall)
                            Spacer(Modifier.height(8.dp))
                            Button(onClick = { launcher.launch(arrayOf("application/epub+zip")) }) {
                                Icon(Icons.Default.Add, null)
                                Spacer(Modifier.width(8.dp))
                                Text("Open EPUB")
                            }
                        }
                    }
                    else -> {
                        LazyColumn(
                            state = listState,
                            contentPadding = PaddingValues(bottom = 100.dp, start = 16.dp, end = 16.dp, top = 16.dp)
                        ) {
                            item { ChapterRenderer(parsedNodes, currentBook!!.uri) }
                            item {
                                Spacer(modifier = Modifier.height(40.dp))
                                Text("--- End of Chapter ${currentChapterIndex + 1} ---",
                                    style = MaterialTheme.typography.labelSmall,
                                    modifier = Modifier.fillMaxWidth().wrapContentWidth(Alignment.CenterHorizontally))
                            }
                        }
                    }
                }

                // Floating Bottom Bar Layer
                AnimatedVisibility(
                    visible = shouldShowBar && currentBook != null,
                    enter = slideInVertically(initialOffsetY = { it }),
                    exit = slideOutVertically(targetOffsetY = { it }),
                    modifier = Modifier.align(Alignment.BottomCenter)
                ) {
                    Surface(
                        modifier = Modifier
                            .padding(24.dp)
                            .fillMaxWidth(),
                        shape = RoundedCornerShape(24.dp),
                        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.95f),
                        tonalElevation = 8.dp,
                        shadowElevation = 6.dp
                    ) {
                        Row(
                            modifier = Modifier
                                .padding(horizontal = 8.dp, vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            // Left actions
                            Row {
                                IconButton(onClick = { scope.launch { drawerState.open() } }) {
                                    Icon(Icons.Default.Menu, "Chapters")
                                }
                                IconButton(onClick = { launcher.launch(arrayOf("application/epub+zip")) }) {
                                    Icon(Icons.Default.Add, "Open")
                                }
                            }

                            // Center: Chapter Title
                            val chapterTitle = remember(currentBook, currentChapterIndex) {
                                val chapterHref = currentBook?.spine?.getOrNull(currentChapterIndex)
                                currentBook?.toc?.get(chapterHref) ?: "Chapter ${currentChapterIndex + 1}"
                            }

                            Text(
                                text = chapterTitle,
                                style = MaterialTheme.typography.labelLarge,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                textAlign = TextAlign.Center,
                                modifier = Modifier
                                    .weight(1f)
                                    .padding(horizontal = 8.dp)
                            )

                            // Right: Navigation
                            Row {
                                IconButton(
                                    onClick = { loadChapter(currentChapterIndex - 1) },
                                    enabled = currentChapterIndex > 0
                                ) {
                                    Icon(Icons.AutoMirrored.Filled.ArrowBack, "Prev")
                                }
                                IconButton(
                                    onClick = { loadChapter(currentChapterIndex + 1) },
                                    enabled = currentChapterIndex < (currentBook?.spine?.size ?: 0) - 1
                                ) {
                                    Icon(Icons.AutoMirrored.Filled.ArrowForward, "Next")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
