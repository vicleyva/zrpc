import express from 'express'
import multer from 'multer'

import { createNote, updateNote, getNotes } from '../controllers/NotesController.js'

const router = express.Router()

router.get("/", getNotes)
router.post("/", createNote)
router.put("/:id", updateNote)

export default router