/**
 * This method create a new note
 * @method
 * @param {express.Request} req
 * @param {express.Response} res
 * @param {express.NextFunction} next
 */

export function index(req, res) {
    res.send("Hello index")
}