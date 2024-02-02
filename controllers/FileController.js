import express from 'express';
import { NotesRepository, NotesDummyRepository } from '../repositories/NotesRepository.js'

/** @type {NotesRepository} */
const notesRepository = new NotesDummyRepository()

/**
 * This method create a new note
 * @method
 * @param {express.Request} req
 * @param {express.Response} res
 * @param {express.NextFunction} next
 */
export function uploadFile(req, res) {
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
export function uploadFileList(req, res) {
    // Tip: Save req.files.filename as the file ID (hashed by multer)
    res.send({
        msg: "file list received",
        files: req.files
    })
}
