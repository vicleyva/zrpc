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
}