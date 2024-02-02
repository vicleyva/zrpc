import NotImplementedException from "../exceptions/NotImplementedException.js";

/**
 * This method create a new note
 * @method
 * @param {express.Request} req
 * @param {express.Response} res
 * @param {express.NextFunction} next
 */
export function index(req, res) {
    throw new NotImplementedException()
    // res.send("Hello index")
}