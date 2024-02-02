import express from 'express';
import logger from '../utils/logger.js'
import { NotesRepository, NotesDummyRepository } from '../repositories/NotesRepository.js'

/** @type {NotesRepository} */
const notesRepository = NotesDummyRepository.getInstance()

/**
 * This method create a new note
 * @method
 * @param {express.Request} req
 * @param {express.Response} res
 * @param {express.NextFunction} next
 */
export async function uploadFile(req, res) {
    const msg = `File ${req.file.filename} has been saved`
    await logger.info(req, msg)
    console.log(msg)

    res.send({
        msg: "file received",
        file: req.file
    })
}


/**
 * This method create a new note
 * @method
 * @param {express.Request} req
 * @param {express.Response} res
 * @param {express.NextFunction} next
 */
export async function uploadFileList(req, res) {
    // Tip: Save req.files.filename as the file ID (hashed by multer)
    res.send({
        msg: "file list received",
        files: req.files
    })
}
