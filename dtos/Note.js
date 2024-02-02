import { mapObjectKeys } from "../utils/mapObjectKeys.js"

/**
 * This represents a Note
 * @class
 */
export class NoteDto {
    /** @type{string}*/         title
    /** @type{string}*/         text
    /** @type{string|bool}*/    color
    /** @type{Array<string>}*/  tags
    /** @type{Array<string>}*/  imgs
    
    /**
     * 
     * @param {any} params 
     * @returns {NoteDto}
     */
    static Create(params) {
        return mapObjectKeys(params, NoteDto)
    }
}

/**
 * This represents a Note in
 * a short format. Useful when 
 * returning NoteShortDto[]
 * @class
 */
export class NoteShortDto {
    /** @type{string} */        id
    /** @type{string}*/         title

    /**
     * 
     * @param {any} params 
     * @returns {NoteShortDto}
     */
    static Create(params) {
        return mapObjectKeys(params, NoteShortDto)
    }
}