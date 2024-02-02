import express from 'express'
// import { createNote, updateNote } from '../controllers/NotesController.js'
import { createNote, updateNote } from '../controllers/NotesController.js'

const router = express.Router()

router.post("/notes", createNote)
router.put("/notes", updateNote)
// router.post("/", NotesController.createNote)
// router.put("/", NotesController.updateNote)

export default router