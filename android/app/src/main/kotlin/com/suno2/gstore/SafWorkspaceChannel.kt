package com.suno2.gstore

import android.app.Activity
import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.util.Log
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.InputStream

/**
 * SAF 外部工作区桥：目录选择、持久化授权、ContentResolver/DocumentsContract 文件操作。
 *
 * 只处理 `content://` 文档树，不把 URI 当文件路径。
 */
private data class SafTreeItem(val docId: String, val relative: String)

object SafWorkspaceChannel {
    private const val TAG = "SafWorkspace"
    private const val CHANNEL = "gstore/saf_workspace"
    const val REQUEST_PICK_TREE = 0x5AF1

    private var activity: Activity? = null
    private lateinit var resolver: ContentResolver
    private var pendingPick: MethodChannel.Result? = null

    fun register(messenger: BinaryMessenger, host: Activity) {
        activity = host
        resolver = host.contentResolver
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            try {
                handle(call, result)
            } catch (e: SecurityException) {
                result.error("PERMISSION", "目录授权已失效，请重新选择目录", null)
            } catch (e: Exception) {
                Log.w(TAG, "SAF 操作失败: ${call.method}", e)
                result.error("SAF", e.message ?: e.toString(), null)
            }
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_PICK_TREE) return
        val pending = pendingPick ?: return
        pendingPick = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            pending.success(null)
            return
        }
        val uri = data.data!!
        try {
            resolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        } catch (e: SecurityException) {
            Log.w(TAG, "持久化目录权限失败", e)
        }
        val name = try {
            displayName(uri, DocumentsContract.getTreeDocumentId(uri))
        } catch (_: Exception) {
            "外部目录"
        }
        pending.success(mapOf("uri" to uri.toString(), "name" to name))
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickDirectory" -> pickDirectory(result)
            "hasPermission" -> result.success(hasPermission(argUri(call)))
            "resolve" -> {
                val uri = argUri(call)
                val path = call.argument<String>("path") ?: ""
                val forWrite = call.argument<Boolean>("forWrite") ?: false
                result.success(resolve(uri, path, forWrite))
            }
            "stat" -> result.success(stat(argUri(call), argPath(call)))
            "list" -> result.success(
                list(
                    argUri(call),
                    argPath(call),
                    call.argument<Boolean>("recursive") ?: false,
                    call.argument<Int>("limit") ?: 500,
                ),
            )
            "read" -> result.success(
                read(
                    argUri(call),
                    argPath(call),
                    call.argument<Int>("maxBytes") ?: (256 * 1024),
                ),
            )
            "readBytes" -> result.success(readBytes(argUri(call), argPath(call)))
            "writeBytes" -> {
                writeBytes(
                    argUri(call),
                    argPath(call),
                    call.argument<ByteArray>("bytes") ?: ByteArray(0),
                    call.argument<Boolean>("create") ?: false,
                )
                result.success(null)
            }
            "delete" -> {
                delete(argUri(call), argPath(call))
                result.success(null)
            }
            "move" -> {
                move(
                    argUri(call),
                    call.argument<String>("source") ?: "",
                    call.argument<String>("target") ?: "",
                )
                result.success(null)
            }
            "mkdir" -> {
                mkdir(argUri(call), argPath(call))
                result.success(null)
            }
            "stats" -> result.success(stats(argUri(call)))
            "clear" -> {
                clear(argUri(call))
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun pickDirectory(result: MethodChannel.Result) {
        val act = activity ?: run {
            result.error("NO_ACTIVITY", "当前页面不可用", null)
            return
        }
        if (pendingPick != null) {
            result.error("BUSY", "已有目录选择进行中", null)
            return
        }
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
            )
        }
        act.startActivityForResult(intent, REQUEST_PICK_TREE)
    }

    private fun argUri(call: MethodCall): Uri =
        Uri.parse(call.argument<String>("uri") ?: "")

    private fun argPath(call: MethodCall): String =
        call.argument<String>("path") ?: ""

    private fun hasPermission(uri: Uri): Boolean {
        if (uri.toString().isEmpty()) return false
        return resolver.persistedUriPermissions?.any {
            it.uri == uri && it.isReadPermission && it.isWritePermission
        } ?: false
    }

    private fun displayName(treeUri: Uri, docId: String): String? {
        val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
        resolver.query(
            docUri,
            arrayOf(Document.COLUMN_DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { c ->
            if (c.moveToFirst()) return c.getString(0)
        }
        return null
    }

    private fun segments(path: String): List<String> {
        val normalized = path.trim().replace('\\', '/')
        if (normalized.startsWith("/")) {
            throw IllegalArgumentException("只允许工作区相对路径")
        }
        if (normalized.isEmpty() || normalized == ".") return emptyList()
        val parts = normalized.split('/').filter { it.isNotEmpty() }
        for (part in parts) {
            if (part == "." || part == ".." || part.contains('\u0000')) {
                throw IllegalArgumentException("路径不能跳出工作区")
            }
        }
        return parts
    }

    private fun relativePath(parts: List<String>): String = parts.joinToString("/")

    private fun findChild(
        treeUri: Uri,
        parentDocId: String,
        name: String,
    ): String? {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri,
            parentDocId,
        )
        resolver.query(
            childrenUri,
            arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { c ->
            while (c.moveToNext()) {
                if (c.getString(1) == name) return c.getString(0)
            }
        }
        return null
    }

    private fun childDocId(
        treeUri: Uri,
        parentDocId: String,
        name: String,
    ): String? = findChild(treeUri, parentDocId, name)

    private fun queryDoc(treeUri: Uri, docId: String): Map<String, Any?> {
        val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
        resolver.query(
            docUri,
            arrayOf(
                Document.COLUMN_DOCUMENT_ID,
                Document.COLUMN_DISPLAY_NAME,
                Document.COLUMN_MIME_TYPE,
                Document.COLUMN_SIZE,
                Document.COLUMN_LAST_MODIFIED,
            ),
            null,
            null,
            null,
        )?.use { c ->
            if (c.moveToFirst()) {
                return mapOf(
                    "docId" to c.getString(0),
                    "name" to c.getString(1),
                    "mime" to c.getString(2),
                    "size" to if (c.isNull(3)) -1L else c.getLong(3),
                    "modifiedAt" to if (c.isNull(4)) 0L else c.getLong(4),
                )
            }
        }
        return mapOf(
            "docId" to docId,
            "name" to null,
            "mime" to null,
            "size" to -1L,
            "modifiedAt" to 0L,
        )
    }

    private fun typeOf(mime: String?): String = when {
        mime == Document.MIME_TYPE_DIR -> "directory"
        mime.isNullOrEmpty() -> "other"
        else -> "file"
    }

    private fun resolve(uri: Uri, path: String, forWrite: Boolean): Map<String, Any?> {
        val treeUri = uri
        val parts = segments(path)
        var currentDoc = DocumentsContract.getTreeDocumentId(treeUri)
        val found = mutableListOf<String>()

        for ((index, part) in parts.withIndex()) {
            val child = childDocId(treeUri, currentDoc, part)
            if (child == null) {
                return mapOf(
                    "relative" to relativePath(parts),
                    "exists" to false,
                    "type" to "other",
                )
            }
            val doc = queryDoc(treeUri, child)
            val type = typeOf(doc["mime"] as String?)
            if (index < parts.size - 1 && type != "directory") {
                throw IllegalArgumentException("路径中间项不是目录: ${relativePath(found)}")
            }
            currentDoc = child
            found.add(part)
        }

        val doc = queryDoc(treeUri, currentDoc)
        return mapOf(
            "relative" to relativePath(found),
            "exists" to true,
            "type" to typeOf(doc["mime"] as String?),
        )
    }

    private fun stat(uri: Uri, path: String): Map<String, Any?> {
        val treeUri = uri
        val parts = segments(path)
        var currentDoc = DocumentsContract.getTreeDocumentId(treeUri)
        val found = mutableListOf<String>()
        for (part in parts) {
            val child = childDocId(treeUri, currentDoc, part) ?: return mapOf(
                "relative" to relativePath(parts),
                "type" to "other",
                "bytes" to 0,
                "modifiedAt" to 0,
            )
            currentDoc = child
            found.add(part)
        }
        val doc = queryDoc(treeUri, currentDoc)
        return mapOf(
            "relative" to relativePath(found),
            "type" to typeOf(doc["mime"] as String?),
            "bytes" to ((doc["size"] as Long?) ?: -1L).coerceAtLeast(0L),
            "modifiedAt" to (doc["modifiedAt"] as Long? ?: 0L),
        )
    }

    private fun list(
        uri: Uri,
        path: String,
        recursive: Boolean,
        limit: Int,
    ): List<Map<String, Any?>> {
        val treeUri = uri
        val parts = segments(path)
        var rootDoc = DocumentsContract.getTreeDocumentId(treeUri)
        for (part in parts) {
            rootDoc = childDocId(treeUri, rootDoc, part)
                ?: throw IllegalArgumentException("目录不存在")
        }
        val out = mutableListOf<Map<String, Any?>>()
        val queue = ArrayDeque<SafTreeItem>()
        queue.add(SafTreeItem(rootDoc, relativePath(parts)))
        while (queue.isNotEmpty() && out.size < limit) {
            val item = queue.removeFirst()
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
                treeUri,
                item.docId,
            )
            resolver.query(
                childrenUri,
                arrayOf(
                    Document.COLUMN_DOCUMENT_ID,
                    Document.COLUMN_DISPLAY_NAME,
                    Document.COLUMN_MIME_TYPE,
                    Document.COLUMN_SIZE,
                    Document.COLUMN_LAST_MODIFIED,
                ),
                null,
                null,
                null,
            )?.use { c ->
                while (c.moveToNext() && out.size < limit) {
                    val docId = c.getString(0)
                    val name = c.getString(1)
                    val mime = c.getString(2)
                    val size = if (c.isNull(3)) 0L else c.getLong(3)
                    val modified = if (c.isNull(4)) 0L else c.getLong(4)
                    val relative = if (item.relative.isEmpty()) {
                        name
                    } else {
                        "${item.relative}/$name"
                    }
                    out.add(
                        mapOf(
                            "path" to relative,
                            "type" to typeOf(mime),
                            "bytes" to size,
                            "modifiedAt" to modified,
                        ),
                    )
                    if (recursive && mime == Document.MIME_TYPE_DIR) {
                        queue.add(SafTreeItem(docId, relative))
                    }
                }
            }
        }
        return out
    }

    private fun read(uri: Uri, path: String, maxBytes: Int): Map<String, Any?> {
        val treeUri = uri
        val parts = segments(path)
        var currentDoc = DocumentsContract.getTreeDocumentId(treeUri)
        for (part in parts) {
            currentDoc = childDocId(treeUri, currentDoc, part)
                ?: throw IllegalArgumentException("文件不存在")
        }
        val doc = queryDoc(treeUri, currentDoc)
        if (typeOf(doc["mime"] as String?) != "file") {
            throw IllegalArgumentException("不是文件")
        }
        val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, currentDoc)
        val input = resolver.openInputStream(docUri)
            ?: throw IllegalArgumentException("无法打开文件")
        val buffer = ByteArrayOutputStream()
        val chunk = ByteArray(16 * 1024)
        var total = 0
        var truncated = false
        input.use { stream: InputStream ->
            while (true) {
                val read = stream.read(chunk)
                if (read <= 0) break
                if (total + read > maxBytes) {
                    val allowed = maxBytes - total
                    if (allowed > 0) buffer.write(chunk, 0, allowed)
                    total += allowed.coerceAtLeast(0)
                    truncated = true
                    break
                }
                buffer.write(chunk, 0, read)
                total += read
            }
        }
        val size = (doc["size"] as Long?) ?: total.toLong()
        if (size > maxBytes) truncated = true
        return mapOf(
            "path" to relativePath(parts),
            "bytes" to buffer.toByteArray(),
            "size" to size,
            "truncated" to truncated,
        )
    }

    private fun readBytes(uri: Uri, path: String): ByteArray {
        val treeUri = uri
        val parts = segments(path)
        var currentDoc = DocumentsContract.getTreeDocumentId(treeUri)
        for (part in parts) {
            currentDoc = childDocId(treeUri, currentDoc, part)
                ?: throw IllegalArgumentException("文件不存在")
        }
        val doc = queryDoc(treeUri, currentDoc)
        if (typeOf(doc["mime"] as String?) != "file") {
            throw IllegalArgumentException("不是文件")
        }
        val size = (doc["size"] as Long?) ?: -1L
        if (size > 5L * 1024 * 1024) {
            throw IllegalArgumentException("文件超过 5MB，暂不支持读取")
        }
        val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, currentDoc)
        val input = resolver.openInputStream(docUri)
            ?: throw IllegalArgumentException("无法打开文件")
        return input.use { it.readBytes() }
    }

    private fun findParent(
        treeUri: Uri,
        parts: List<String>,
    ): String? {
        var currentDoc = DocumentsContract.getTreeDocumentId(treeUri)
        for (part in parts) {
            currentDoc = childDocId(treeUri, currentDoc, part) ?: return null
        }
        return currentDoc
    }

    private fun ensureParent(
        treeUri: Uri,
        parts: List<String>,
    ): String {
        var currentDoc = DocumentsContract.getTreeDocumentId(treeUri)
        for (part in parts) {
            val existing = childDocId(treeUri, currentDoc, part)
            if (existing != null) {
                val doc = queryDoc(treeUri, existing)
                if (typeOf(doc["mime"] as String?) != "directory") {
                    throw IllegalArgumentException("路径中间项不是目录: $part")
                }
                currentDoc = existing
            } else {
                val parentUri = DocumentsContract.buildDocumentUriUsingTree(
                    treeUri,
                    currentDoc,
                )
                val created = DocumentsContract.createDocument(
                    resolver,
                    parentUri,
                    Document.MIME_TYPE_DIR,
                    part,
                ) ?: throw IllegalStateException("创建目录失败: $part")
                currentDoc = DocumentsContract.getDocumentId(created)
            }
        }
        return currentDoc
    }

    private fun writeBytes(
        uri: Uri,
        path: String,
        bytes: ByteArray,
        create: Boolean,
    ) {
        val treeUri = uri
        val parts = segments(path)
        if (parts.isEmpty()) throw IllegalArgumentException("路径不能为空")
        val parentDoc = ensureParent(treeUri, parts.dropLast(1))
        val name = parts.last()
        val existing = childDocId(treeUri, parentDoc, name)
        val docUri: Uri
        if (existing != null) {
            if (create) throw IllegalArgumentException("文件已存在，请使用 write 覆盖")
            val doc = queryDoc(treeUri, existing)
            if (typeOf(doc["mime"] as String?) == "directory") {
                throw IllegalArgumentException("目标是目录")
            }
            docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, existing)
        } else {
            val parentUri = DocumentsContract.buildDocumentUriUsingTree(
                treeUri,
                parentDoc,
            )
            docUri = DocumentsContract.createDocument(
                resolver,
                parentUri,
                mimeTypeFor(name),
                name,
            ) ?: throw IllegalStateException("创建文件失败")
        }
        val output = (
            try {
                resolver.openOutputStream(docUri, "wt")
            } catch (_: Exception) {
                resolver.openOutputStream(docUri, "w")
            }
        ) ?: throw IllegalStateException("无法写入文件")
        output.use {
            it.write(bytes)
            it.flush()
        }
    }

    private fun mimeTypeFor(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            ?: "application/octet-stream"
    }

    private fun delete(uri: Uri, path: String) {
        val treeUri = uri
        val parts = segments(path)
        if (parts.isEmpty()) throw IllegalArgumentException("不能删除工作区根目录")
        val parentDoc = findParent(treeUri, parts.dropLast(1))
            ?: throw IllegalArgumentException("目录不存在")
        val name = parts.last()
        val docId = childDocId(treeUri, parentDoc, name)
            ?: throw IllegalArgumentException("文件或目录不存在")
        val doc = queryDoc(treeUri, docId)
        val type = typeOf(doc["mime"] as String?)
        if (type == "directory") {
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
                treeUri,
                docId,
            )
            val hasChild = resolver.query(
                childrenUri,
                arrayOf(Document.COLUMN_DOCUMENT_ID),
                null,
                null,
                null,
            )?.use { it.moveToFirst() } ?: false
            if (hasChild) throw IllegalArgumentException("目录不为空，无法删除")
        }
        val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
        if (!DocumentsContract.deleteDocument(resolver, docUri)) {
            throw IllegalStateException("删除失败")
        }
    }

    private fun move(uri: Uri, source: String, target: String) {
        val treeUri = uri
        val srcParts = segments(source)
        val dstParts = segments(target)
        if (srcParts.isEmpty() || dstParts.isEmpty()) {
            throw IllegalArgumentException("路径不能为空")
        }
        val srcParent = findParent(treeUri, srcParts.dropLast(1))
            ?: throw IllegalArgumentException("源目录不存在")
        val srcName = srcParts.last()
        val srcDoc = childDocId(treeUri, srcParent, srcName)
            ?: throw IllegalArgumentException("源文件不存在")
        val dstParent = ensureParent(treeUri, dstParts.dropLast(1))
        val dstName = dstParts.last()
        if (childDocId(treeUri, dstParent, dstName) != null) {
            throw IllegalArgumentException("目标已存在")
        }
        val srcUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, srcDoc)
        if (srcParent == dstParent) {
            DocumentsContract.renameDocument(resolver, srcUri, dstName)
                ?: throw IllegalStateException("重命名失败")
        } else {
            val srcParentUri = DocumentsContract.buildDocumentUriUsingTree(
                treeUri,
                srcParent,
            )
            val dstParentUri = DocumentsContract.buildDocumentUriUsingTree(
                treeUri,
                dstParent,
            )
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
                throw IllegalStateException("当前系统不支持跨目录移动")
            }
            DocumentsContract.moveDocument(
                resolver,
                srcUri,
                srcParentUri,
                dstParentUri,
            ) ?: throw IllegalStateException("移动失败（目录可能不支持）")
        }
    }

    private fun mkdir(uri: Uri, path: String) {
        val treeUri = uri
        val parts = segments(path)
        if (parts.isEmpty()) throw IllegalArgumentException("路径不能为空")
        val parentDoc = ensureParent(treeUri, parts.dropLast(1))
        val name = parts.last()
        val existing = childDocId(treeUri, parentDoc, name)
        if (existing != null) {
            val doc = queryDoc(treeUri, existing)
            if (typeOf(doc["mime"] as String?) == "directory") return
            throw IllegalArgumentException("同名文件已存在")
        }
        val parentUri = DocumentsContract.buildDocumentUriUsingTree(
            treeUri,
            parentDoc,
        )
        DocumentsContract.createDocument(
            resolver,
            parentUri,
            Document.MIME_TYPE_DIR,
            name,
        ) ?: throw IllegalStateException("创建目录失败")
    }

    private fun stats(uri: Uri): Map<String, Any?> {
        val treeUri = uri
        val rootDoc = DocumentsContract.getTreeDocumentId(treeUri)
        var files = 0
        var bytes = 0L
        val queue = ArrayDeque<String>()
        queue.add(rootDoc)
        var visited = 0
        while (queue.isNotEmpty() && visited < 5000) {
            val parent = queue.removeFirst()
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
                treeUri,
                parent,
            )
            resolver.query(
                childrenUri,
                arrayOf(
                    Document.COLUMN_DOCUMENT_ID,
                    Document.COLUMN_MIME_TYPE,
                    Document.COLUMN_SIZE,
                ),
                null,
                null,
                null,
            )?.use { c ->
                while (c.moveToNext() && visited < 5000) {
                    visited++
                    val docId = c.getString(0)
                    val mime = c.getString(1)
                    val size = if (c.isNull(2)) 0L else c.getLong(2)
                    if (mime == Document.MIME_TYPE_DIR) {
                        queue.add(docId)
                    } else {
                        files++
                        if (size > 0) bytes += size
                    }
                }
            }
        }
        return mapOf("files" to files, "bytes" to bytes)
    }

    private fun clear(uri: Uri) {
        val treeUri = uri
        val rootDoc = DocumentsContract.getTreeDocumentId(treeUri)
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri,
            rootDoc,
        )
        val children = mutableListOf<String>()
        resolver.query(
            childrenUri,
            arrayOf(Document.COLUMN_DOCUMENT_ID),
            null,
            null,
            null,
        )?.use { c ->
            while (c.moveToNext()) children.add(c.getString(0))
        }
        for (child in children) {
            val childUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, child)
            DocumentsContract.deleteDocument(resolver, childUri)
        }
    }
}
