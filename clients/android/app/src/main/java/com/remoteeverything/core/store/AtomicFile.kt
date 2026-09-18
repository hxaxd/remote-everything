package com.remoteeverything.core.store

import java.io.File

/**
 * A file that is replaced, never edited: the new contents are written beside it
 * and renamed over it, so a reader sees either the whole old file or the whole
 * new one. Anything that must survive being killed halfway is written this way.
 */
object AtomicFile {

    fun write(file: File, contents: ByteArray) {
        file.parentFile?.mkdirs()
        val temporary = File(file.parentFile, file.name + ".new")
        temporary.writeBytes(contents)
        if (!temporary.renameTo(file)) {
            // Windows refuses a rename onto an existing file; replacing it first is
            // still atomic enough: the old file is whole until the rename lands.
            file.delete()
            if (!temporary.renameTo(file)) {
                temporary.delete()
                throw java.io.IOException("could not replace ${file.name}")
            }
        }
    }

    fun read(file: File): ByteArray? = if (file.isFile) file.readBytes() else null

    fun delete(file: File) {
        if (file.exists() && !file.delete()) {
            throw java.io.IOException("could not delete ${file.name}")
        }
    }
}
