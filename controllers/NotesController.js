import express from 'express';
import { NotesRepository, NotesDummyRepository } from '../repositories/NotesRepository.js'
import { Note } from "../entities/Note.js"
import { NewNoteDto } from "../dtos/NoteDto.js"


const notesRepository = new NotesDummyRepository()
console.log("New Notes Repository Instance...")

/**
 * This method create a new note
 * @method
 * @param {express.Request} req
 * @param {express.Response} res
 * @param {express.NextFunction} next
 */
export function createNote(req, res) {
    console.log("on execution (NotesController.createNote)")

    // We  create a new note entity
    // to mutate existing data
    const newNote = req.body;
    const note = Note.mapFromDto(newNote)

    notesRepository.saveNewNote(note)

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
    const existingNote = req.body
    const note = Note.mapFromDto(existingNote)

    notesRepository.updateNote(note)

    res.status = 200
    res.statusText = "updated!"
    res.json({ message: "updated" })
}


// exports
// export default {createNote, updateNote}
// exports.createPlace = createPlace;
// exports.updateNote = updateNote;
