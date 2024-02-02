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
 * @class
 * @implements {NotesRepository}
 */
export class NotesRepositoryImpl {
    
    db
    constructor(db) {
        this.db = db
    }
    
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
        console.log("[repository] Dummy Repository Single Instance")    
    }
    
    saveNewNote(note) {
        throw new NotImplementedException()
        console.log("created in db...", note)
    }
    
    updateNote(note) {
        console.log("updated in db...", note)
    }
    
    /**
     * Get Singleton Instance
     * @static @method
     * @returns {NotesDummyRepository}
    */
   // https://bootcamp.uxdesign.cc/understanding-the-singleton-pattern-ac9d30c3abdd
    static getInstance() {
       if(!NotesDummyRepository.instance) {
           NotesDummyRepository.instance = new NotesDummyRepository()
        }
        return NotesDummyRepository.instance
    }
    static instance = null
}