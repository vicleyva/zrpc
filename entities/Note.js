import { NewNoteDto } from '../dtos/NoteDto.js'

/**
 * This is the Note Entity that matches
 * 1 on 1 with our db table.
 * Here, we will mutate data for 
 * our domain rules (business rules)
 */
export class Note {
    /** @type{string}*/         id
    /** @type{string}*/         title
    /** @type{string}*/         text
    /** @type{string|bool}*/    color
    /** @type{Array<File>}*/    img
    /** @type{Array<string>}*/  tags
    constructor({id, title, text, color, img, tags }) {
        this.id = id || ""
        this.title = title
        this.text = text
        this.color = color
        this.img = img
        this.tags = tags
    }

    /**
     * This will map data from dto
     * to our entity.
     * @method
     * @param {NewNoteDto} newNote
     * @return {Note}
     */
    static mapFromDto(newNote = new NewNoteDto()) {
        return new Note(newNote)
    }
}
