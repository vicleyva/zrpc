/**
 * this is the data from the JSON
 * @class
 */
export class NewNoteDto {
    /** @type{string}*/         title
    /** @type{string}*/         text
    /** @type{string|bool}*/    color
    /** @type{Array<File>}*/    img
    /** @type{Array<string>}*/  tags
}