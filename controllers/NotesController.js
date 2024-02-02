import express from 'express';
import logger from '../utils/logger.js';
import { NotesRepository, NotesDummyRepository } from '../repositories/NotesRepository.js'
import { Note } from "../entities/Note.js"
import { NoteDto, NoteShortDto } from "../dtos/Note.js"
import { mapObjectKeys } from '../utils/mapObjectKeys.js'
import headers from '../midleware/HeadersMiddleware.js';

/** @type {NotesRepository} */
const notesRepository = NotesDummyRepository.getInstance()


/**
 * This method create a new note
 * @method
 * @param {express.Request} req
 * @param {express.Response} res
 * @param {express.NextFunction} next
 */
export async function getNotes(req, res) {
    res.status = 200
    res.statusMessage = "allnotes"
    await logger.info(req, res, "notes retrieved succesfully")
    res.json({
        notes: [
            NoteShortDto.Create({
                id: "uuid-001",
                title: "title 001"
            }),
            NoteShortDto.Create({
                id: "uuid-002",
                title: "title 002"
            }),
            NoteShortDto.Create({
                id: "uuid-003",
                title: "title 003"
            })
        ]
    })
}

/**
 * This method create a new note
 * @method
 * @param {express.Request} req
 * @param {express.Response} res
 * @param {express.NextFunction} next
 */
export async function createNote(req, res) {
    // We  create a new note entity
    // to mutate existing data
    /** @type {NoteDto} */
    const noteDto = req.body;

    // We must validate request body (to be discussed...)
    // When request body is valid we map the DTO to our Entity
    // and save into repository
    /** @type {Note} */
    const note = mapObjectKeys(noteDto, Note)

    try {
        notesRepository.saveNewNote(note)
        res.status(201)
        res.statusMessage = "created"
        await logger.info(req, res, `note created with id: ${note.id}`)
        res.json({ message: "saved!" })
    }
    catch(err) {
        res.status(500)
        res.statusMessage = "error:create"
        await logger.info(req, res, `note failed to created: ${err.message}`)
        return res.json({ message: "saved!", requestId: req.headers[headers.XRequestId] })
    }
}


/**
* This method updates an existing note
* @method
* @param {express.Request} req
* @param {express.Response} res
* @param {express.NextFunction} next
*/
export async function updateNote(req, res) {
    
    // We  create a new note entity
    // to mutate existing data
    /** @type {NoteDto} */
    const noteDto = req.body

    /** @type {Note} */
    const note = mapObjectKeys(noteDto, Note)
    note.id = req.params.id // Set the ID from URL (/notes/:id)

    // We save the entity using our repository
    notesRepository.updateNote(note)

    
    res.status = 200
    res.statusMessage = "updated"
    await logger.info(req, res, `note updated with id: ${note.id}`)
    res.json({ message: "updated" })
}