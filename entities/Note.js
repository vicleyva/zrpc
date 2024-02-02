import { v4 as uuidv4 } from 'uuid';

/**
 * This is the Note Entity that matches
 * 1 on 1 with our db table.
 * Here, we will mutate data for 
 * our domain rules (business rules)
 */
export class Note {

    /**
     * 
     * @param {string} id 
     * @param {string} title 
     * @param {string} text 
     * @param {string} color 
     * @param {Array<File>} imgs 
     * @param {Array<string>} tags 
     */
    constructor(id, title, text, color, imgs, tags) {
        this.id = id ?? uuidv4() // If no id set, create new id on the fly
        this.title = title
        this.text = text
        this.color = color
        this.imgs = imgs
        this.tags = tags
    }

    // getChecksumFromFile(indx) {
        
    // }
}
