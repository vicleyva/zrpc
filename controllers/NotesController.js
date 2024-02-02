import express from 'express';
import { NotesRepository, NotesDummyRepository } from '../repositories/NotesRepository.js'
import { Note } from "../entities/Note.js"
import { NoteDto, NoteShortDto } from "../dtos/Note.js"
import { mapObjectKeys } from '../utils/mapObjectKeys.js'

/** @type {NotesRepository} */
const notesRepository = new NotesDummyRepository()


/**
 * This method create a new note
 * @method
 * @param {express.Request} req
 * @param {express.Response} res
 * @param {express.NextFunction} next
 */
export function getNotes(req, res) {
    res.json({
        notes: [
            new NoteShortDto()
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
export function createNote(req, res) {
    // We  create a new note entity
    // to mutate existing data
    /** @type {NoteDto} */
    const noteDto = req.body;

    // We must validate request body (to be discussed...)

    // When request body is valid we map the DTO to our Entity
    // and save into repository
    notesRepository.saveNewNote(mapObjectKeys(noteDto, Note))

    res.status = 201
    res.statusText = "saved!"
    return res.json({ message: "saved!" })
}


/**
* This method updates an existing note
* @method
* @param {express.Request} req
* @param {express.Response} res
* @param {express.NextFunction} next
*/
export function updateNote(req, res) {
    
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
    res.statusText = "updated!"
    res.json({ message: "updated" })
}