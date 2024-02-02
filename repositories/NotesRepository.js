import NotImplementedException from '../exceptions/NotImplementedException.js'
import { Note } from '../entities/Note.js'

/**
 * This is the Notes repository
 * @interface
 */
export class NotesRepository {

    /**
     * This method save a new Note
     * @method
     * @param {Note} note
     */
    saveNewNote(note) {
        throw new NotImplementedException()
    }

    /**
     * This method updates a note in db
     * @param {Note} note
     */
    updateNote(note) {
        throw new NotImplementedException()
    }

}

/**
 * This will only print data to console log
 * @class
 * @implements {NotesRepository}
 */
export class NotesDummyRepository {

    constructor(){
        console.log("Creation of dummy repository")
    }

    saveNewNote(note) {
        console.log("created in db...", note)
    }

    updateNote(note) {
        console.log("updated in db...", note)
    }

}