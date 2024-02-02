/**
 * Raise exception on non implemented code
 * @class
 */
export default class NotImplementedException extends Error {
    constructor(message) {
        super(message); // (1)
        this.name = "NotImplementedException"; // (2)
    }
}

